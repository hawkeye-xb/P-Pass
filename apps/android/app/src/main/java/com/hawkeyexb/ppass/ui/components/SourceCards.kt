package com.hawkeyexb.ppass.ui.components

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
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
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
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
    role: Role,
    stateDescription: String?,
    tag: String?,
    onClick: () -> Unit,
    cover: @Composable BoxScope.() -> Unit,
    content: @Composable RowScope.() -> Unit,
    enabled: Boolean = true,
    attention: Boolean = false,
    footer: (@Composable () -> Unit)? = null,
) {
    Card(
        onClick = onClick,
        enabled = enabled,
        // 角色、选中状态与点击动作挂在同一个可点击节点上：屏幕阅读器对带标题的节点
        // 执行双击时，语义动作就在这个节点自身，能真正触发 onClick。
        modifier = Modifier
            .fillMaxWidth()
            .then(if (tag == null) Modifier else Modifier.testTag(tag))
            .semantics(mergeDescendants = true) {
                this.role = role
                if (stateDescription != null) {
                    this.selected = selected
                    this.stateDescription = stateDescription
                }
            },
        shape = RoundedCornerShape(16.dp),
        colors = sourceCardColors(selected),
        border = BorderStroke(
            width = if (selected || attention) 2.dp else 1.dp,
            color = when {
                attention -> PPColor.Act
                selected -> PPColor.Ink
                else -> PPColor.Border
            },
        ),
    ) {
        Column {
            Box(modifier = Modifier.fillMaxWidth().height(180.dp), content = cover)
            // 内容区只给最小高度：大字号下标题换行时整行跟着长高，数量标签不会被挤成 0。
            Row(
                modifier = Modifier.fillMaxWidth().heightIn(min = 72.dp).padding(horizontal = 12.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                content()
            }
            footer?.invoke()
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
    statusLabel: String? = null,
    actionLabel: String? = null,
    onAction: (() -> Unit)? = null,
) {
    SourceCellFrame(
        selected = selected,
        role = Role.Checkbox,
        stateDescription = if (selected) selectedDescription else unselectedDescription,
        tag = tag,
        onClick = onClick,
        attention = statusLabel != null,
        cover = {
            cover()
            if (statusLabel != null) {
                Surface(
                    modifier = Modifier.align(Alignment.TopStart).padding(8.dp),
                    shape = RoundedCornerShape(6.dp),
                    color = PPColor.ActBg,
                ) {
                    Text(
                        text = statusLabel,
                        style = MaterialTheme.typography.labelSmall,
                        fontWeight = FontWeight.Bold,
                        color = PPColor.Act,
                        modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp),
                    )
                }
            }
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
            Icon(
                imageVector = if (kind == SourceKind.ALBUM) Icons.AutoMirrored.Filled.List else Icons.Default.Menu,
                contentDescription = kindLabel,
                modifier = Modifier.padding(end = 8.dp).size(20.dp),
                tint = if (statusLabel != null) PPColor.Act else PPColor.Ink60,
            )
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = title,
                    style = MaterialTheme.typography.bodyMedium,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    text = statusLabel ?: countLabel,
                    style = MaterialTheme.typography.bodySmall,
                    color = if (statusLabel != null) PPColor.Act else PPColor.Ink40,
                )
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
        },
        footer = if (actionLabel != null && onAction != null) {
            {
                OutlinedButton(
                    onClick = onAction,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(start = 12.dp, end = 12.dp, bottom = 10.dp)
                        .heightIn(min = 40.dp),
                    shape = RoundedCornerShape(12.dp),
                    border = BorderStroke(1.dp, PPColor.Act.copy(alpha = 0.45f)),
                    colors = ButtonDefaults.outlinedButtonColors(
                        containerColor = PPColor.ActBg,
                        contentColor = PPColor.Act,
                    ),
                ) {
                    Text(
                        text = actionLabel,
                        style = MaterialTheme.typography.labelLarge,
                        fontWeight = FontWeight.Bold,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
        } else {
            null
        },
    )
}

@Composable
fun AddSourceCard(
    label: String,
    actionContentDescription: String,
    onClick: () -> Unit,
    tag: String? = null,
    enabled: Boolean = true,
) {
    SourceCellFrame(
        selected = false,
        role = Role.Button,
        stateDescription = null,
        tag = tag,
        onClick = onClick,
        enabled = enabled,
        cover = {
            Icon(
                imageVector = Icons.Default.Add,
                contentDescription = actionContentDescription,
                modifier = Modifier.align(Alignment.Center).size(32.dp),
                tint = PPColor.Ink60,
            )
        },
        content = {
            Text(
                text = label,
                style = MaterialTheme.typography.bodyMedium,
                fontWeight = FontWeight.SemiBold,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
        },
    )
}
