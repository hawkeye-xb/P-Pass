package com.hawkeyexb.ppass.probe

import android.app.job.JobInfo
import android.app.job.JobScheduler
import android.content.ClipData
import android.content.ClipboardManager
import android.content.ComponentName
import android.content.Context
import android.os.Bundle
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            MaterialTheme(colorScheme = darkColorScheme()) {
                Surface(modifier = Modifier.fillMaxSize()) {
                    ProbeScreen()
                }
            }
        }
    }
}

@Composable
fun ProbeScreen(vm: ProbeViewModel = viewModel()) {
    val state by vm.uiState.collectAsState()
    val context = LocalContext.current

    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(16.dp)
            .verticalScroll(rememberScrollState()),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        // Header
        Text("P-Pass Probe", style = MaterialTheme.typography.headlineMedium)
        Text("S-03 · iroh-ffi on Android", style = MaterialTheme.typography.bodySmall)

        Divider()

        // Bind button
        if (!state.isBound) {
            Button(
                onClick = { vm.bind() },
                modifier = Modifier.fillMaxWidth(),
                enabled = state.status != "Binding...",
            ) {
                Text(if (state.status == "Binding...") "Binding..." else "Bind Endpoint")
            }
        } else {
            // Node info
            OutlinedTextField(
                value = state.nodeId,
                onValueChange = {},
                label = { Text("Node ID") },
                readOnly = true,
                modifier = Modifier.fillMaxWidth(),
                singleLine = true,
                trailingIcon = {
                    TextButton(onClick = {
                        copyToClipboard(context, state.nodeId)
                        Toast.makeText(context, "Node ID copied", Toast.LENGTH_SHORT).show()
                    }) {
                        Text("Copy")
                    }
                }
            )

            OutlinedTextField(
                value = state.ticket,
                onValueChange = {},
                label = { Text("Ticket") },
                readOnly = true,
                modifier = Modifier.fillMaxWidth(),
                minLines = 3,
                trailingIcon = {
                    TextButton(onClick = {
                        copyToClipboard(context, state.ticket)
                        Toast.makeText(context, "Ticket copied", Toast.LENGTH_SHORT).show()
                    }) {
                        Text("Copy")
                    }
                }
            )

            Divider()

            // Dial section
            Text("Dial Peer", style = MaterialTheme.typography.titleMedium)
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                OutlinedTextField(
                    value = state.dialInput,
                    onValueChange = { vm.updateDialInput(it) },
                    label = { Text("Paste ticket") },
                    modifier = Modifier.weight(1f),
                    singleLine = true,
                )
                Button(
                    onClick = { vm.dial() },
                    enabled = state.dialInput.isNotBlank(),
                ) {
                    Text("Dial")
                }
            }

        // S-04: UIDT stress test (background transfer)
        Divider()
        Text("UIDT Stress Test", style = MaterialTheme.typography.titleMedium)
        Text(
            "100 MB × 20 loops in background via JobService.",
            style = MaterialTheme.typography.bodySmall,
        )

        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            OutlinedTextField(
                value = state.dialInput,
                onValueChange = { vm.updateDialInput(it) },
                label = { Text("Remote ticket") },
                modifier = Modifier.weight(1f),
                singleLine = true,
            )
            Button(
                onClick = {
                    scheduleUidtTransfer(context, state.dialInput.trim())
                    vm.markUidtStarted()
                },
                enabled = state.dialInput.isNotBlank() && !state.uidtTransferring,
            ) {
                Text(if (state.uidtTransferring) "Running…" else "Start UIDT")
            }
        }

        // UIDT status
        if (state.uidtStatus.isNotEmpty()) {
            Text("UIDT: ${state.uidtStatus}", style = MaterialTheme.typography.bodySmall)
        }

        // Share UIDT log
        if (state.uidtTransferring) {
            TextButton(onClick = {
                val logText = UidtLogger.readLogAsText(context)
                val shareIntent = android.content.Intent(android.content.Intent.ACTION_SEND).apply {
                    type = "text/plain"
                    putExtra(android.content.Intent.EXTRA_TEXT, logText)
                    putExtra(android.content.Intent.EXTRA_SUBJECT, "UIDT Log")
                }
                context.startActivity(android.content.Intent.createChooser(shareIntent, "Share UIDT Log"))
            }) {
                Text("Share Log")
            }
        }
        }

        // Status (always visible)
        Text("Status: ${state.status}", style = MaterialTheme.typography.bodyMedium)

        if (state.isBound) {
            Divider()

            // Results section
            if (state.results.isNotEmpty()) {
                Text("Results", style = MaterialTheme.typography.titleMedium)
                ResultsTable(state.results)
            }
        }
    }
}

@Composable
fun ResultsTable(results: List<ProbeResult>) {
    // Header
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text("#", modifier = Modifier.width(30.dp), style = MaterialTheme.typography.labelSmall)
        Text("Path", modifier = Modifier.width(60.dp), style = MaterialTheme.typography.labelSmall)
        Text("IP", modifier = Modifier.width(30.dp), style = MaterialTheme.typography.labelSmall)
        Text("Connect", modifier = Modifier.width(70.dp), style = MaterialTheme.typography.labelSmall)
        Text("Mbps", modifier = Modifier.width(70.dp), style = MaterialTheme.typography.labelSmall)
        Text("Error", modifier = Modifier.weight(1f), style = MaterialTheme.typography.labelSmall)
    }

    results.takeLast(20).forEach { r ->
        val fg = if (r.error != null) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurface
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text(
                "${r.attempt}",
                modifier = Modifier.width(30.dp),
                style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
                color = fg,
            )
            Text(
                r.path,
                modifier = Modifier.width(60.dp),
                style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
                color = fg,
            )
            Text(
                r.ipver,
                modifier = Modifier.width(30.dp),
                style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
                color = fg,
            )
            Text(
                if (r.connectMs > 0) "${r.connectMs}ms" else "-",
                modifier = Modifier.width(70.dp),
                style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
                color = fg,
            )
            Text(
                "%.0f".format(r.throughputMbps),
                modifier = Modifier.width(70.dp),
                style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
                color = fg,
            )
            Text(
                r.error ?: "",
                modifier = Modifier.weight(1f),
                style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
                color = fg,
                maxLines = 1,
            )
        }
    }
}

fun copyToClipboard(context: Context, text: String) {
    val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
    clipboard.setPrimaryClip(ClipData.newPlainText("iroh-probe", text))
}

/** S-04: Schedule the UIDT background transfer job. */
fun scheduleUidtTransfer(context: Context, ticket: String) {
    val js = context.getSystemService(Context.JOB_SCHEDULER_SERVICE) as JobScheduler
    val component = ComponentName(context, UidtTransferService::class.java)

    val jobInfo = JobInfo.Builder(1, component)
        .setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY)
        .setExtras(android.os.PersistableBundle().apply {
            putString(UidtTransferService.EXTRA_TICKET, ticket)
        })
        .build()

    js.schedule(jobInfo)
    Toast.makeText(context, "UIDT transfer scheduled", Toast.LENGTH_SHORT).show()
}
