package com.hawkeyexb.ppass.probe

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

data class ProbeUiState(
    val nodeId: String = "",
    val ticket: String = "",
    val status: String = "Ready",
    val results: List<ProbeResult> = emptyList(),
    val dialInput: String = "",
    val isBound: Boolean = false,
    // S-04: UIDT mode
    val uidtStatus: String = "",
    val uidtTransferring: Boolean = false,
)

class ProbeViewModel : ViewModel() {
    private val probe = IrohProbe()
    private val _uiState = MutableStateFlow(ProbeUiState())
    val uiState: StateFlow<ProbeUiState> = _uiState.asStateFlow()

    fun bind() {
        viewModelScope.launch {
            _uiState.value = _uiState.value.copy(status = "Binding...")
            probe.bind().onSuccess { ticket ->
                _uiState.value = _uiState.value.copy(
                    nodeId = probe.nodeId() ?: "",
                    ticket = ticket,
                    status = "Listening",
                    isBound = true,
                )
                probe.startListener { result ->
                    val current = _uiState.value.results.toMutableList()
                    current.add(result)
                    _uiState.value = _uiState.value.copy(results = current)
                }
            }.onFailure { e ->
                _uiState.value = _uiState.value.copy(
                    status = "Bind failed: ${e.message}"
                )
            }
        }
    }

    fun updateDialInput(text: String) {
        _uiState.value = _uiState.value.copy(dialInput = text)
    }

    fun dial() {
        val ticket = _uiState.value.dialInput.trim()
        if (ticket.isBlank()) return

        val attempt = _uiState.value.results.size + 1
        _uiState.value = _uiState.value.copy(
            status = "Connecting...",
            dialInput = "",
        )

        viewModelScope.launch {
            val result = probe.dial(ticket, payloadMegaBytes = 100)
            val current = _uiState.value.results.toMutableList()
            current.add(result.copy(attempt = attempt))
            _uiState.value = _uiState.value.copy(
                status = if (result.error != null) "Error" else "Done",
                results = current,
            )
        }
    }

    /** S-04: Mark UIDT transfer as started (the real work is in the JobService). */
    fun markUidtStarted() {
        _uiState.value = _uiState.value.copy(
            uidtStatus = "Job scheduled",
            uidtTransferring = true,
        )
    }

    override fun onCleared() {
        super.onCleared()
        probe.shutdown()
    }
}
