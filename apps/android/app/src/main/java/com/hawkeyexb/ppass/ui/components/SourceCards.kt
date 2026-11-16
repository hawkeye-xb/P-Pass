package com.hawkeyexb.ppass.ui.components

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.automirrored.filled.List
import androidx.compose.material.icons.filled.Menu
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.hawkeyexb.ppass.ui.PPColor
import com.hawkeyexb.ppass.ui.PPSize

/** The only visual distinction between source types is the standard icon and its description. */
enum class SourceKind { ALBUM, FOLDER }

data class SourceMenuAction(val label: String, val onClick: () -> Unit)

@Composable
private fun sourceCardColors(selected: Boolean) = CardDefaults.cardColors(
    containerColor = if (selected) PPColor.Paper else PPColor.Linen,
    contentColor = PPColor.Ink,
)

@Composable
private fun SourceCellFrame(
    selected: Boolean,
    tag: String?,
    onClick: () -> Unit,
    cover: @Composable BoxScope.() -> Unit,
    content: @Composable RowScope.() -> Unit,
) {
    Card(
        onClick = onClick,
        modifier = Modifier
            .fillMaxWidth()
            .then(if (tag == null) Modifier else Modifier.testTag(tag)),
        shape = RoundedCornerShape(16.dp),
        colors = sourceCardColors(selected),
        border = BorderStroke(if (selected) 2.dp else 1.dp, if (selected) PPColor.Ink else PPColor.Border),
    ) {
        Column {
            Box(modifier = Modifier.fillMaxWidth().height(180.dp), content = cover)
                Row(
                    modifier = Modifier.fillMaxWidth().height(72.dp).padding(horizontal = 12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    content()
                }
        }
    }
}

@Composable
fun SourceCard(
    title: String,
    countLabel: String,
    kind: SourceKind,
    kindLabel: String,
    selected: Boolean,
    selectedDescription: String,
    unselectedDescription: String,
    onClick: () -> Unit,
    cover: @Composable BoxScope.() -> Unit,
    menuActions: List<SourceMenuAction> = emptyList(),
    menuContentDescription: String = "更多操作",
    tag: String? = null,
) {
    SourceCellFrame(
        selected = selected,
        tag = tag,
        onClick = onClick,
        cover = {
            cover()
            Surface(
                modifier = Modifier.align(Alignment.TopEnd).padding(8.dp).size(24.dp),
                shape = CircleShape,
                color = if (selected) PPColor.Ink else PPColor.PaperDim,
                border = if (selected) null else BorderStroke(1.dp, PPColor.BorderStrong),
            ) {
                if (selected) {
                    Icon(
                        imageVector = Icons.Default.Check,
                        contentDescription = selectedDescription,
                        modifier = Modifier.padding(4.dp),
                        tint = PPColor.Paper,
                    )
                }
            }
        },
        content = {
            SourceCellFrameSemantics(selected, selectedDescription, unselectedDescription) {
                Icon(
                    imageVector = if (kind == SourceKind.ALBUM) Icons.AutoMirrored.Filled.List else Icons.Default.Menu,
                    contentDescription = kindLabel,
                    modifier = Modifier.padding(end = 8.dp).size(20.dp),
                    tint = PPColor.Ink60,
                )
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = title,
                        style = MaterialTheme.typography.bodyMedium,
                        fontWeight = FontWeight.SemiBold,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                    Text(text = countLabel, style = MaterialTheme.typography.bodySmall, color = PPColor.Ink40)
                }
                if (menuActions.isNotEmpty()) {
                    var expanded by remember { mutableStateOf(false) }
                    Box {
                        IconButton(onClick = { expanded = true }, modifier = Modifier.size(PPSize.TapMin)) {
                            Icon(Icons.Default.MoreVert, contentDescription = menuContentDescription)
                        }
                        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
                            menuActions.forEach { action ->
                                DropdownMenuItem(
                                    text = { Text(action.label) },
                                    onClick = {
                                        expanded = false
                                        action.onClick()
                                    },
                                )
                            }
                        }
                    }
                }
            }
        },
    )
}

@Composable
private fun SourceCellFrameSemantics(
    selected: Boolean,
    selectedDescription: String,
    unselectedDescription: String,
    content: @Composable () -> Unit,
) {
    Box(
        modifier = Modifier.semantics(mergeDescendants = true) {
            role = Role.Checkbox
            this.selected = selected
            stateDescription = if (selected) selectedDescription else unselectedDescription
        },
    ) {
        content()
    }
}

@Composable
fun AddSourceCard(
    label: String,
    actionContentDescription: String,
    onClick: () -> Unit,
    tag: String? = null,
) {
    SourceCellFrame(
        selected = false,
        tag = tag,
        onClick = onClick,
        cover = {
            Icon(
                imageVector = Icons.Default.Add,
                contentDescription = actionContentDescription,
                modifier = Modifier.align(Alignment.Center).size(32.dp),
                tint = PPColor.Ink60,
            )
        },
        content = {
            Box(modifier = Modifier.semantics(mergeDescendants = true) { role = Role.Button }) {
                Text(
                    text = label,
                    style = MaterialTheme.typography.bodyMedium,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        },
    )
}
