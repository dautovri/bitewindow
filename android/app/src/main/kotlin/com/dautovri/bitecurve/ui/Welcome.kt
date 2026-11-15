package com.dautovri.bitecurve.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.MyLocation
import androidx.compose.material.icons.filled.Place
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Verified
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.dautovri.bitecurve.R

enum class WelcomeChoice { LOCATE, SEARCH, SKIP }

/**
 * First launch: what the app does in three lines, then straight to finding a water. The
 * point is a real forecast for the angler's own spot within the first minute.
 */
@Composable
fun WelcomeScreen(onChoice: (WelcomeChoice) -> Unit) {
    val colors = Theme.colors
    Box(Modifier.fillMaxSize().background(colors.background).safeDrawingPadding(), contentAlignment = Alignment.TopCenter) {
        Column(
            Modifier.widthIn(max = 520.dp).verticalScroll(rememberScrollState()).padding(horizontal = 24.dp).padding(top = 36.dp, bottom = 24.dp),
            horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(28.dp),
        ) {
            Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(14.dp)) {
                Box(Modifier.size(96.dp).background(colors.accent.copy(alpha = 0.14f), CircleShape), contentAlignment = Alignment.Center) {
                    FishIcon(Modifier.size(52.dp))
                }
                Text(stringResource(R.string.know_when_the_fish_bite), style = MaterialTheme.typography.headlineLarge, fontWeight = FontWeight.Bold, color = colors.primaryText, textAlign = TextAlign.Center)
                Text(stringResource(R.string.a_bite_forecast_for_your_own_lake_river_or_stret), style = MaterialTheme.typography.titleMedium, color = colors.secondaryText, textAlign = TextAlign.Center)
            }
            Column(Modifier.padding(horizontal = 4.dp), verticalArrangement = Arrangement.spacedBy(18.dp)) {
                WelcomePoint(Icons.Filled.Schedule, R.string.the_best_two_hours_of_the_day, R.string.a_0_100_bite_index_from_light_wind_pressure_wate)
                WelcomePoint(Icons.Filled.Place, R.string.for_the_water_you_fish, R.string.drop_a_pin_on_any_lake_or_sea_no_account_needed)
                WelcomePoint(Icons.Filled.Verified, R.string.honest_about_what_it_knows, R.string.it_is_an_estimate_from_published_fisheries_resea)
            }
            Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Button({ onChoice(WelcomeChoice.LOCATE) }, Modifier.fillMaxWidth().heightIn(min = 52.dp)) {
                    Icon(Icons.Filled.MyLocation, null, Modifier.size(18.dp))
                    Spacer(Modifier.width(8.dp))
                    Text(stringResource(R.string.use_my_location), style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                }
                OutlinedButton({ onChoice(WelcomeChoice.SEARCH) }, Modifier.fillMaxWidth().heightIn(min = 52.dp)) {
                    Icon(Icons.Filled.Search, null, Modifier.size(18.dp))
                    Spacer(Modifier.width(8.dp))
                    Text(stringResource(R.string.search_for_a_lake_or_sea), style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                }
                TextButton({ onChoice(WelcomeChoice.SKIP) }) { Text(stringResource(R.string.look_around_first), color = colors.secondaryText) }
            }
        }
    }
}

@Composable
private fun WelcomePoint(icon: ImageVector, title: Int, detail: Int) {
    Row(Modifier.fillMaxWidth().semantics(mergeDescendants = true) {}, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
        Icon(icon, null, Modifier.size(26.dp), tint = Theme.colors.accent)
        Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(stringResource(title), style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, color = Theme.colors.primaryText)
            Text(stringResource(detail), style = MaterialTheme.typography.bodyMedium, color = Theme.colors.secondaryText)
        }
    }
}
