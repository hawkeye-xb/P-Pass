// ARCH-03: strict single-head consumer over ARCH-02's durable ledger facts.
package com.hawkeyexb.ppass.backup.flow

/** A controllable seam for the later native fetch adapter. */
interface DeliveryPort {
    fun start(item: TransferItem, resumePartial: Boolean, lease: FetchLease)
    fun stop(queueSequence: Long): PartialDisposition
}

enum class PartialDisposition {
    RETAINED,
    DISCARDED,
}

/**
 * NET-06: notifies the daemon that one exact tuple should stop being
 * waited on. Used by [CancellationRoundController] for items that already
 * made real contact with the daemon (a `flow.offer` was sent for them at
 * some point) — plain QUEUED items that were never offered have nothing
 * to tell the daemon about and must not call this.
 *
 * Best-effort per NET-06's card principle 1 (意图先行，不等回声): the
 * phone's own local cancellation state change (already durable before
 * this is called) must never be blocked or rolled back by a failure here.
 * Implementations must swallow their own exceptions — this is a courtesy
 * notification, not a two-phase commit.
 */
fun interface FlowTupleCancelPort {
    fun cancel(item: TransferItem)
}

/** Default seam for existing production wiring and tests that don't care
 *  about tuple cancellation — a silent no-op. */
object NoopFlowTupleCancelPort : FlowTupleCancelPort {
    override fun cancel(item: TransferItem) = Unit
}

/**
 * Consumes exactly one queued item at a time. Scheduler wakes call [wake]; they
 * never decide Pause/Continue semantics or bypass the durable upload cursor.
 */
class StrictConsumer(
    private val ledger: DiscoveryLedgerStore,
    private val delivery: DeliveryPort,
    // MOB-88: 起飞这个副作用（整文件哈希 + 原生注册 + offer）必须离开状态
    // 决策线程。默认就地执行 = 改造前的同步语义，测试断言不受影响。
    private val effects: FlowEffectSink = InlineFlowEffects,
) {
    fun wake(constraintsSatisfied: Boolean) {
        val current = ledger.load()
        if (current.consumerGate == ConsumerGate.PAUSED_BY_USER) return

        if (!constraintsSatisfied) {
            waitForConstraints(current)
            return
        }

        if (current.fetchLease != null) return
        val head = headOf(current) ?: run {
            ledger.update { it.copy(consumerStatus = ConsumerStatus.IDLE) }
            return
        }
        val lease = FetchLease(queueSequence = head.queueSequence, leaseToken = "lease-${head.queueSequence}")
        val transferring = head.copy(deliveryState = DeliveryState.TRANSFERRING)
        ledger.update { snapshot ->
            snapshot.copy(
                uploadCursor = UploadCursor(head.queueSequence),
                consumerStatus = ConsumerStatus.IDLE,
                fetchLease = lease,
                items = snapshot.items.map { item ->
                    if (item.queueSequence == head.queueSequence) transferring else item
                },
            )
        }
        // NET: `head` is the pre-update snapshot (deliveryState == QUEUED).
        // delivery.start() persists its own follow-up ledger.update (e.g.
        // NativeFlowDeliveryPort filling in contentHash) by copying the
        // `item` it was handed and writing that copy back whole — passing
        // the stale `head` here made that follow-up write clobber the
        // TRANSFERRING we just persisted above back to QUEUED. fetchLease
        // stayed correct (nothing here touches it), so the transfer itself
        // was never double-started or lost — only the item's own
        // deliveryState field lied. But FlowUiProjection reads exactly this
        // field to pick the "currently uploading" item for the progress UI,
        // so the user-visible symptom was indistinguishable from a stuck
        // transfer: no file ever showed as transferring while one was
        // genuinely in flight (real device, 2026-09-16, Samsung SM-S9210).
        // Passing the already-TRANSFERRING copy means start()'s own
        // ledger.update writes TRANSFERRING back, not QUEUED.
        //
        // MOB-88: 起飞离开写者线程后，租约有可能在它真正动手之前就被后续
        // action 收走（用户暂停、约束失效、代号更换）。所以动手前再读一次
        // 内存里的权威状态确认租约还是自己的——不是则本次作废，什么都不做。
        // 就地执行（测试）时这次检查恒真，行为与改造前一致。
        effects.submit {
            if (ledger.load().fetchLease?.leaseToken != lease.leaseToken) return@submit
            delivery.start(transferring, resumePartial = head.partialRetained, lease = lease)
        }
    }

    fun pauseByUser() {
        val current = ledger.load()
        val lease = current.fetchLease ?: run {
            ledger.update { snapshot ->
                // MOB-63: a receipt can clear the final lease just before the
                // user Pause reaches this branch. Pausing an already-drained
                // round must not invent resumable work or a stale Resume UI.
                val hasDeliverableWork = snapshot.items.any {
                    it.deliveryState == DeliveryState.QUEUED ||
                        it.deliveryState == DeliveryState.TRANSFERRING
                }
                val paused = if (hasDeliverableWork) {
                    snapshot.copy(consumerGate = ConsumerGate.PAUSED_BY_USER)
                } else {
                    snapshot.copy(
                        consumerGate = ConsumerGate.OPEN,
                        consumerStatus = ConsumerStatus.IDLE,
                        fetchLease = null,
                    )
                }
                // AUDIT-01: pause is a durable user action even when there is
                // nothing in flight to actually stop.
                paused.appendAudit(AuditKinds.ROUND_CONTROLLED, roundId = snapshot.currentRoundId, payload = mapOf("action" to "pause"))
            }
            return
        }
        val partial = delivery.stop(lease.queueSequence)
        ledger.update { snapshot ->
            val items = snapshot.items.map { item ->
                if (item.queueSequence == lease.queueSequence) {
                    item.copy(
                        deliveryState = DeliveryState.QUEUED,
                        partialRetained = partial == PartialDisposition.RETAINED,
                    )
                } else {
                    item
                }
            }
            snapshot.copy(
                consumerGate = ConsumerGate.PAUSED_BY_USER,
                consumerStatus = ConsumerStatus.IDLE,
                fetchLease = null,
                items = items,
            ).appendAudit(AuditKinds.ROUND_CONTROLLED, roundId = snapshot.currentRoundId, payload = mapOf("action" to "pause"))
        }
    }

    fun continueByUser() {
        ledger.update { it.copy(consumerGate = ConsumerGate.OPEN, consumerStatus = ConsumerStatus.IDLE) }
        wake(constraintsSatisfied = true)
    }

    /**
     * A [FetchLease] recorded by an earlier process life is not evidence of
     * a live transfer in THIS one — the coroutine that held it (and the
     * native provider registration behind it) died with that process, or
     * the daemon serving it was restarted out from under it. [wake]'s
     * `fetchLease != null` short-circuit has no way to tell that apart
     * from a genuinely in-flight lease from earlier in the SAME process
     * life, so it never re-offers — every future wake spins straight to
     * IDLE forever with the item stuck QUEUED/TRANSFERRING (real device,
     * 2026-09-16: `am force-stop` mid-offer left exactly this orphan;
     * `adb install -r` preserves app data, so the stale lease survived
     * the reinstall too).
     *
     * Call exactly once, when [AndroidFlowRuntime] is first constructed
     * for a process life (never on every wake, or an in-flight lease from
     * earlier in the SAME process life would be reset out from under its
     * own delivery). Demotes the leased item back to QUEUED so the very
     * next [wake] can lease and (re)send it — same shape as
     * [waitForConstraints], minus the `delivery.stop()` call, since there
     * is no live delivery object in this fresh process to stop.
     */
    fun reconcileProcessStart() {
        val current = ledger.load()
        val lease = current.fetchLease ?: return
        ledger.update { snapshot ->
            snapshot.copy(
                consumerStatus = ConsumerStatus.IDLE,
                fetchLease = null,
                items = snapshot.items.map { item ->
                    if (item.queueSequence == lease.queueSequence && item.deliveryState == DeliveryState.TRANSFERRING) {
                        item.copy(deliveryState = DeliveryState.QUEUED)
                    } else {
                        item
                    }
                },
            )
        }
    }

    /**
     * A discovered MediaStore URI disappeared before its bytes could be offered.
     * This is terminal local fact, not a retryable transport failure: a retry
     * cannot recreate a photo the user deleted.
     */
    fun skipMissingSource() {
        val current = ledger.load()
        val lease = current.fetchLease ?: run {
            ledger.update { it.rejected("skip_missing_source", "no_active_lease") }
            return
        }
        ledger.update { snapshot ->
            val item = snapshot.items.single { it.queueSequence == lease.queueSequence }
            val items = snapshot.items.map { item ->
                if (item.queueSequence == lease.queueSequence) {
                    item.copy(
                        deliveryState = DeliveryState.SKIPPED_SOURCE_MISSING,
                        sourcePresence = SourcePresence.MISSING,
                        disposition = RecoveryDisposition.UNRECOVERABLE,
                        partialRetained = false,
                    )
                } else item
            }
            val nextCursor = items.firstOrNull { it.deliveryState == DeliveryState.QUEUED }
                ?.let { UploadCursor(it.queueSequence) }
                ?: UploadCursor.INITIAL
            // AUDIT-04: a discovered source vanishing before it could be sent
            // is a durable, terminal object fact (case matrix §3) — commit it
            // in the same atomic snapshot as the state transition.
            snapshot.copy(
                uploadCursor = nextCursor,
                consumerStatus = ConsumerStatus.IDLE,
                fetchLease = null,
                items = items,
            ).appendAudit(
                AuditKinds.ITEM_SOURCE_MISSING,
                roundId = item.roundId,
                payload = mapOf(
                    "itemRef" to item.sourceRef,
                    "queueSequence" to lease.queueSequence.toString(),
                ),
            )
        }
    }

    /**
     * MOB-67: returns whether THIS call drove the leased head into the
     * terminal FAILED_NEEDS_USER state (attempt 3 of 3). The caller may not
     * re-derive it from a post-update read — a concurrent restore or receipt
     * could change the picture between write and read; the transition itself
     * is the fact.
     */
    fun recordPermanentFailure(): Boolean {
        val current = ledger.load()
        // MOB-88: 没有活跃租约说明这条失败的依据已经不成立（暂停/取消/代号
        // 更换先落地了）。改造前这里静默 return，于是竞态发生时系统不出声。
        val lease = current.fetchLease ?: run {
            ledger.update { it.rejected("permanent_failure", "no_active_lease") }
            return false
        }
        var becameTerminal = false
        ledger.update { snapshot ->
            val currentItem = snapshot.items.single { it.queueSequence == lease.queueSequence }
            val attempts = currentItem.attemptCount + 1
            val terminal = attempts >= MAX_PERMANENT_ATTEMPTS
            // MOB-67: captured inside the mutation itself — the exact
            // transition into FAILED_NEEDS_USER is the durable fact the
            // failure notification hooks (a transient retry stays silent).
            becameTerminal = terminal
            val items = snapshot.items.map { item ->
                if (item.queueSequence == lease.queueSequence) {
                    item.copy(
                        deliveryState = if (terminal) DeliveryState.FAILED_NEEDS_USER else DeliveryState.QUEUED,
                        attemptCount = attempts,
                    )
                } else {
                    item
                }
            }
            val nextCursor = if (terminal) {
                items.firstOrNull { it.deliveryState == DeliveryState.QUEUED }
                    ?.let { UploadCursor(it.queueSequence) }
                    ?: UploadCursor.INITIAL
            } else {
                snapshot.uploadCursor
            }
            val next = snapshot.copy(
                uploadCursor = nextCursor,
                consumerStatus = ConsumerStatus.IDLE,
                fetchLease = null,
                items = items,
            )
            // AUDIT-01: the retry budget is exhausted — this is now a
            // durable "needs a user decision" fact, not a silent retry.
            if (terminal) {
                next.appendAudit(
                    AuditKinds.ITEM_ATTENTION,
                    roundId = currentItem.roundId,
                    payload = mapOf(
                        "reason" to "delivery_failed",
                        "queueSequence" to lease.queueSequence.toString(),
                        "itemRef" to currentItem.sourceRef,
                    ),
                )
            } else {
                next
            }
        }
        return becameTerminal
    }

    private fun waitForConstraints(current: DiscoveryLedgerSnapshot) {
        val lease = current.fetchLease
        val partial = lease?.let { delivery.stop(it.queueSequence) }
        ledger.update { snapshot ->
            snapshot.copy(
                consumerStatus = ConsumerStatus.WAITING_FOR_CONSTRAINTS,
                fetchLease = null,
                items = snapshot.items.map { item ->
                    if (lease != null && item.queueSequence == lease.queueSequence) {
                        item.copy(
                            deliveryState = DeliveryState.QUEUED,
                            partialRetained = partial == PartialDisposition.RETAINED,
                        )
                    } else {
                        item
                    }
                },
            )
        }
    }

    private fun headOf(snapshot: DiscoveryLedgerSnapshot): TransferItem? {
        val cursor = snapshot.uploadCursor.currentQueueSequence
        return if (cursor != null) {
            snapshot.items.singleOrNull {
                it.queueSequence == cursor && it.deliveryState == DeliveryState.QUEUED
            }
        } else {
            snapshot.items.firstOrNull { it.deliveryState == DeliveryState.QUEUED }
        }
    }

    private companion object {
        const val MAX_PERMANENT_ATTEMPTS = 3
    }
}
