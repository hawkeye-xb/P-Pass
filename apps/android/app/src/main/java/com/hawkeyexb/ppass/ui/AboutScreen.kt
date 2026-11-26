package com.hawkeyexb.ppass.ui

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.hawkeyexb.ppass.R
import java.util.Locale

internal data class AboutLinkItem(
    val id: String,
    val labelRes: Int,
    val valueRes: Int? = null,
    val literalValue: String? = null,
    val url: String,
)

internal fun isChineseLocale(locale: Locale = Locale.getDefault()): Boolean =
    locale.language.equals("zh", ignoreCase = true)

internal fun aboutLinks(isChinese: Boolean): List<AboutLinkItem> {
    val prefix = if (isChinese) "https://p-pass.hawkeye-xb.com/zh" else "https://p-pass.hawkeye-xb.com"
    return listOf(
        AboutLinkItem(
            id = "website",
            labelRes = R.string.about_website,
            url = "$prefix/",
        ),
        AboutLinkItem(
            id = "faq",
            labelRes = R.string.about_faq,
            url = "$prefix/faq/",
        ),
        AboutLinkItem(
            id = "feedback_email",
            labelRes = R.string.about_feedback_email,
            literalValue = "ppass@hawkeye-xb.com",
            url = "mailto:ppass@hawkeye-xb.com",
        ),
        AboutLinkItem(
            id = "feedback_discussions",
            labelRes = R.string.about_feedback_discussions,
            literalValue = "GitHub",
            url = "https://github.com/hawkeye-xb/P-Pass/discussions",
        ),
        AboutLinkItem(
            id = "source",
            labelRes = R.string.about_source_code,
            valueRes = R.string.about_source_license,
            url = "https://github.com/hawkeye-xb/P-Pass",
        ),
        AboutLinkItem(
            id = "privacy",
            labelRes = R.string.about_privacy,
            url = "$prefix/privacy/",
        ),
    )
}

internal fun openExternalUrlIntent(
    url: String,
    parseUri: (String) -> Uri = Uri::parse,
    makeIntent: (String, Uri) -> Intent = { action, uri -> Intent(action, uri) },
): Intent {
    val action = if (url.startsWith("mailto:", ignoreCase = true)) {
        Intent.ACTION_SENDTO
    } else {
        Intent.ACTION_VIEW
    }
    return makeIntent(action, parseUri(url))
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun AboutPage(
    versionLine: String,
    onOpenUrl: (String) -> Unit,
    onBack: () -> Unit,
) {
    val locales = LocalConfiguration.current.locales
    val locale = if (!locales.isEmpty) locales[0] else Locale.getDefault()
    val links = aboutLinks(isChineseLocale(locale))

    Scaffold(
        modifier = Modifier.fillMaxSize(),
        containerColor = PPColor.Paper,
        topBar = {
            TopAppBar(
                title = {
                    Text(
                        stringResource(R.string.about_label),
                        style = MaterialTheme.typography.headlineSmall.copy(fontFamily = PPFont.Serif),
                        color = PPColor.Ink,
                        modifier = Modifier.semantics { heading() },
                    )
                },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(
                            imageVector = Icons.AutoMirrored.Filled.ArrowBack,
                            contentDescription = stringResource(R.string.back),
                            tint = PPColor.Ink,
                        )
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = PPColor.Paper,
                    scrolledContainerColor = PPColor.Paper,
                    navigationIconContentColor = PPColor.Ink,
                    titleContentColor = PPColor.Ink,
                ),
            )
        },
    ) { innerPadding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .background(PPColor.Paper)
                .padding(innerPadding)
                .verticalScroll(rememberScrollState())
                .padding(20.dp, 14.dp, 20.dp, 24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Spacer(Modifier.height(8.dp))
            Surface(
                color = PPColor.Paper,
                shape = RoundedCornerShape(PPSize.RadiusControl),
                border = BorderStroke(1.dp, PPColor.Border),
                modifier = Modifier.size(68.dp),
            ) {
                Image(
                    painter = painterResource(R.mipmap.ic_launcher_foreground),
                    contentDescription = null,
                    modifier = Modifier.fillMaxSize().padding(6.dp),
                )
            }
            Spacer(Modifier.height(12.dp))
            Text(
                text = "P-Pass",
                style = MaterialTheme.typography.titleLarge.copy(fontFamily = PPFont.Serif),
                color = PPColor.Ink,
            )
            Spacer(Modifier.height(4.dp))
            Text(
                text = versionLine,
                style = MaterialTheme.typography.labelMedium,
                color = PPColor.Ink40,
                textAlign = TextAlign.Center,
            )
            Spacer(Modifier.height(8.dp))
            Text(
                text = stringResource(R.string.about_tagline),
                style = MaterialTheme.typography.bodyMedium,
                color = PPColor.Ink60,
                textAlign = TextAlign.Center,
            )
            Spacer(Modifier.height(20.dp))
            Surface(
                color = PPColor.Paper,
                shape = RoundedCornerShape(PPSize.RadiusCard),
                border = BorderStroke(1.dp, PPColor.Border),
                modifier = Modifier.fillMaxWidth(),
            ) {
                Column {
                    links.forEachIndexed { index, item ->
                        if (index > 0) {
                            HorizontalDivider(color = PPColor.Divider)
                        }
                        val value = item.valueRes?.let { stringResource(it) } ?: item.literalValue
                        CellRow(
                            label = stringResource(item.labelRes),
                            value = value,
                            onClick = { onOpenUrl(item.url) },
                        )
                    }
                }
            }
        }
    }
}
