package com.dautovri.bitecurve.ui

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/**
 * The app's surfaces and accents, the same values as App/BiteWindow/Views/Theme.swift: cool
 * water tones, dark enough before dawn and legible in daylight.
 */
class BiteColors(
    /** Behind everything. */
    val background: Color,
    /** A card on the background. */
    val card: Color,
    /** A recessed strip or pill inside a card. */
    val well: Color,
    /** Hairline around a card. */
    val stroke: Color,
    /** Buttons, links, the selected tab. */
    val accent: Color,
    /** The tide curve. */
    val tide: Color,
    val primaryText: Color,
    val secondaryText: Color,
    /** Night on the bite curve. */
    val night: Color,
    val isDark: Boolean,
) {
    /** The dark panel that carries Pro; the same in light and dark. */
    val deepWater = Color(0xFF0F293A)

    /** Colour for a bite index: four clearly different steps, a slow day is quiet slate. */
    fun bite(index: Double?): Color = when {
        index == null -> secondaryText
        index >= 65 -> if (isDark) Color(0xFF34D399) else Color(0xFF059669)
        index >= 50 -> if (isDark) Color(0xFF22D3EE) else Color(0xFF0891B2)
        index >= 35 -> if (isDark) Color(0xFFFBBF24) else Color(0xFFD97706)
        else -> if (isDark) Color(0xFF94A3B8) else Color(0xFF64748B)
    }

    val positive: Color get() = if (isDark) Color(0xFF34D399) else Color(0xFF059669)
    val negative: Color get() = if (isDark) Color(0xFFFBBF24) else Color(0xFFD97706)
}

private val Light = BiteColors(
    background = Color(0xFFEEF3F6), card = Color(0xFFFFFFFF), well = Color(0xFFE3ECF2),
    stroke = Color(0xFFCBD5E1).copy(alpha = 0.45f), accent = Color(0xFF0D9488), tide = Color(0xFF0284C7),
    primaryText = Color(0xFF0B1522), secondaryText = Color(0xFF5B6B7A),
    night = Color(0xFF0B1522).copy(alpha = 0.07f), isDark = false,
)

private val Dark = BiteColors(
    background = Color(0xFF07111A), card = Color(0xFF0E1E2B), well = Color(0xFF15293A),
    stroke = Color(0xFF38BDF8).copy(alpha = 0.14f), accent = Color(0xFF2DD4BF), tide = Color(0xFF38BDF8),
    primaryText = Color(0xFFF1F5F9), secondaryText = Color(0xFF94A3B8),
    night = Color(0xFF000000).copy(alpha = 0.32f), isDark = true,
)

val LocalBiteColors = staticCompositionLocalOf { Light }

object Theme {
    val colors: BiteColors @Composable get() = LocalBiteColors.current
    val cardRadius = 20.dp
    val wellRadius = 12.dp
    val gap = 14.dp
    val cardPadding = 16.dp
    /** Cards never grow wider than this on tablets. */
    val readableWidth = 640.dp
}

@Composable
fun BiteTheme(content: @Composable () -> Unit) {
    val colors = if (isSystemInDarkTheme()) Dark else Light
    val scheme = if (colors.isDark) {
        darkColorScheme(
            primary = colors.accent, onPrimary = Color(0xFF04201D), background = colors.background, onBackground = colors.primaryText,
            surface = colors.card, onSurface = colors.primaryText, surfaceVariant = colors.well, onSurfaceVariant = colors.secondaryText,
            surfaceContainer = colors.card, surfaceContainerHigh = colors.card, surfaceContainerHighest = colors.well,
            surfaceContainerLow = colors.card, secondaryContainer = colors.accent.copy(alpha = 0.22f), onSecondaryContainer = colors.accent,
            outline = colors.secondaryText.copy(alpha = 0.5f), outlineVariant = colors.stroke,
        )
    } else {
        lightColorScheme(
            primary = colors.accent, onPrimary = Color.White, background = colors.background, onBackground = colors.primaryText,
            surface = colors.card, onSurface = colors.primaryText, surfaceVariant = colors.well, onSurfaceVariant = colors.secondaryText,
            surfaceContainer = colors.card, surfaceContainerHigh = colors.card, surfaceContainerHighest = colors.well,
            surfaceContainerLow = colors.card, secondaryContainer = colors.accent.copy(alpha = 0.16f), onSecondaryContainer = colors.accent,
            outline = colors.secondaryText.copy(alpha = 0.5f), outlineVariant = colors.stroke,
        )
    }
    CompositionLocalProvider(LocalBiteColors provides colors) {
        MaterialTheme(colorScheme = scheme, content = content)
    }
}

/** A card on the app background: padded, rounded, with a hairline. */
@Composable
fun BiteCard(
    modifier: Modifier = Modifier,
    padding: Dp = Theme.cardPadding,
    onClick: (() -> Unit)? = null,
    content: @Composable () -> Unit,
) {
    val shape = RoundedCornerShape(Theme.cardRadius)
    val border = BorderStroke(1.dp, Theme.colors.stroke)
    if (onClick != null) {
        Surface(onClick = onClick, modifier = modifier.fillMaxWidth(), shape = shape, color = Theme.colors.card, border = border) {
            Box(Modifier.padding(padding)) { content() }
        }
    } else {
        Surface(modifier = modifier.fillMaxWidth(), shape = shape, color = Theme.colors.card, border = border) {
            Box(Modifier.padding(padding)) { content() }
        }
    }
}

/** A recessed strip inside a card. */
@Composable
fun Well(modifier: Modifier = Modifier, padding: PaddingValues = PaddingValues(horizontal = 12.dp, vertical = 10.dp), content: @Composable () -> Unit) {
    Box(modifier.background(Theme.colors.well, RoundedCornerShape(Theme.wellRadius)).padding(padding)) { content() }
}

/** A small heading above a card. */
@Composable
fun CardHeader(title: String) {
    Text(
        title, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold, color = Theme.colors.secondaryText,
        modifier = Modifier.padding(horizontal = 4.dp).semantics { heading() },
    )
}
