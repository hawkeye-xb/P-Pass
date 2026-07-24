package com.hawkeyexb.ppass.probe

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.os.Bundle
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
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
            ) {
                Text("Bind Endpoint")
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

            // Status
            Text("Status: ${state.status}", style = MaterialTheme.typography.bodyMedium)

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
