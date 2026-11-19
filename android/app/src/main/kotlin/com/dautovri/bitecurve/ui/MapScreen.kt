package com.dautovri.bitecurve.ui

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.location.Address
import android.location.Geocoder
import android.location.LocationManager
import android.net.Uri
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Cancel
import androidx.compose.material.icons.filled.MyLocation
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.layout
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.core.location.LocationManagerCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.dautovri.bitecurve.R
import com.dautovri.bitecurve.billing.Entitlements
import com.dautovri.bitecurve.core.Forecaster
import com.dautovri.bitecurve.core.Species
import com.dautovri.bitecurve.core.SpeciesOutlook
import com.dautovri.bitecurve.core.Terms
import com.dautovri.bitecurve.core.TideStation
import com.dautovri.bitecurve.core.WaterType
import com.dautovri.bitecurve.data.ForecastService
import com.dautovri.bitecurve.data.Spot
import com.dautovri.bitecurve.data.WaterReading
import com.dautovri.bitecurve.data.nowSeconds
import com.dautovri.bitecurve.data.startOfDay
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import org.maplibre.android.MapLibre
import org.maplibre.android.camera.CameraPosition
import org.maplibre.android.camera.CameraUpdateFactory
import org.maplibre.android.geometry.LatLng
import org.maplibre.android.maps.MapLibreMap
import org.maplibre.android.maps.MapView
import java.util.Locale
import kotlin.math.abs
import kotlin.math.roundToInt

/** Something the Map tab should do as soon as it is in front (from the welcome screen). */
enum class MapRequest { LOCATE, SEARCH }

/** Which fish the water at a spot suits right now. */
private class SpotOutlook(val reading: WaterReading?, val ranked: List<SpeciesOutlook>)

/** A place the geocoder found for the search text. */
private class Place(val title: String, val subtitle: String, val latitude: Double, val longitude: Double)

private fun places(addresses: List<Address>?): List<Place> = (addresses ?: emptyList()).filter { it.hasLatitude() && it.hasLongitude() }.map { a ->
    val title = a.featureName?.takeIf { it.any(Char::isLetter) } ?: a.locality ?: a.adminArea ?: a.countryName ?: ""
    val subtitle = listOfNotNull(a.locality, a.adminArea, a.countryName).filter { it != title }.distinct().joinToString(", ")
    Place(title, subtitle, a.latitude, a.longitude)
}.filter { it.title.isNotEmpty() }

/** Android's own geocoder: no key and no account. Empty when it does not answer (offline). */
@Suppress("DEPRECATION")
private suspend fun search(context: Context, query: String): List<Place> = withContext(Dispatchers.IO) {
    if (!Geocoder.isPresent()) return@withContext emptyList()
    runCatching { places(Geocoder(context, Locale.getDefault()).getFromLocationName(query, 5)) }.getOrDefault(emptyList())
}

/** What the geocoder knows about the crosshair: a name to suggest and the country. */
private class Suggestion(val name: String? = null, val regionCode: String? = null)

@Suppress("DEPRECATION")
private suspend fun lookup(context: Context, latitude: Double, longitude: Double): Suggestion =
    // Three seconds at most, so adding a spot never hangs without signal.
    withTimeoutOrNull(3000) {
        withContext(Dispatchers.IO) {
            if (!Geocoder.isPresent()) return@withContext Suggestion()
            val a = runCatching { Geocoder(context, Locale.getDefault()).getFromLocation(latitude, longitude, 1)?.firstOrNull() }.getOrNull()
            Suggestion(a?.locality ?: a?.subAdminArea ?: a?.adminArea, a?.countryCode)
        }
    } ?: Suggestion()

private fun hasLocationPermission(context: Context): Boolean =
    ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED ||
        ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED

/** The phone's position once, for centring the map. The permission must already be granted. */
@Suppress("MissingPermission")
private fun currentLocation(context: Context, onResult: (LatLng?) -> Unit) {
    val manager = context.getSystemService(LocationManager::class.java)
    val providers = manager.getProviders(true)
    val last = providers.mapNotNull { runCatching { manager.getLastKnownLocation(it) }.getOrNull() }.maxByOrNull { it.time }
    if (last != null && System.currentTimeMillis() - last.time < 10 * 60_000) return onResult(LatLng(last.latitude, last.longitude))
    val provider = listOf(LocationManager.NETWORK_PROVIDER, LocationManager.GPS_PROVIDER).firstOrNull { it in providers }
        ?: return onResult(last?.let { LatLng(it.latitude, it.longitude) })
    val signal: android.os.CancellationSignal? = null
    LocationManagerCompat.getCurrentLocation(manager, provider, signal, ContextCompat.getMainExecutor(context), androidx.core.util.Consumer<android.location.Location?> { location ->
        val best = location ?: last
        onResult(best?.let { LatLng(it.latitude, it.longitude) })
    })
}

/**
 * Spots on a map. A spot is dropped at the map centre, so no location permission is needed;
 * "my location" asks for it only when tapped.
 */
@Composable
fun MapScreen(request: MapRequest?, onRequestHandled: () -> Unit, onFirstSpot: (Spot) -> Unit, onPaywall: (PaywallContext) -> Unit) {
    val app = app()
    val context = LocalContext.current
    val colors = Theme.colors
    val dark = isSystemInDarkTheme()
    val scope = rememberCoroutineScope()
    val focus = LocalFocusManager.current
    val data by app.store.data.collectAsStateWithLifecycle()
    val unlimitedSpots by app.entitlements.hasUnlimitedSpots.collectAsStateWithLifecycle()
    val lastPrefetch by app.forecasts.lastPrefetch.collectAsStateWithLifecycle()
    val spots = data.spots

    var map by remember { mutableStateOf<MapLibreMap?>(null) }
    /** Counts camera moves, so the pins drawn over the map follow it. */
    var cameraTick by remember { mutableIntStateOf(0) }
    var center by remember { mutableStateOf<LatLng?>(null) }
    var selectedSpotId by remember { mutableStateOf<String?>(null) }
    var myLocation by remember { mutableStateOf<LatLng?>(null) }
    var showLocationHelp by remember { mutableStateOf(false) }
    var query by remember { mutableStateOf("") }
    var results by remember { mutableStateOf<List<Place>>(emptyList()) }
    /** Set while the field shows the chosen place's name, which is not a new search. */
    var showingChoice by remember { mutableStateOf(false) }
    val searchFocus = remember { FocusRequester() }
    /** The crosshair position the lookup was made for; the spot is saved exactly there. */
    var pending by remember { mutableStateOf<LatLng?>(null) }
    var suggestion by remember { mutableStateOf(Suggestion()) }
    var lookingUp by remember { mutableStateOf(false) }
    /** Today's best-window index and the fish the water suits, per spot, from saved forecasts. */
    var indices by remember { mutableStateOf<Map<String, Double?>>(emptyMap()) }
    var outlooks by remember { mutableStateOf<Map<String, SpotOutlook?>>(emptyMap()) }

    val mapView = remember {
        MapLibre.getInstance(context)
        MapView(context).apply { onCreate(null) }
    }
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    DisposableEffect(lifecycle) {
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_START -> mapView.onStart()
                Lifecycle.Event.ON_RESUME -> mapView.onResume()
                Lifecycle.Event.ON_PAUSE -> mapView.onPause()
                Lifecycle.Event.ON_STOP -> mapView.onStop()
                else -> {}
            }
        }
        lifecycle.addObserver(observer)
        if (lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)) mapView.onStart()
        if (lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)) mapView.onResume()
        onDispose {
            lifecycle.removeObserver(observer)
            mapView.onPause()
            mapView.onStop()
            mapView.onDestroy()
        }
    }
    LaunchedEffect(Unit) {
        mapView.getMapAsync { m ->
            m.uiSettings.isRotateGesturesEnabled = false
            m.uiSettings.isTiltGesturesEnabled = false
            m.uiSettings.isLogoEnabled = false
            m.uiSettings.isCompassEnabled = false
            // The "i" with the map credits: clear of the search field and the add button.
            m.uiSettings.attributionGravity = android.view.Gravity.BOTTOM or android.view.Gravity.END
            val first = app.store.data.value.spots.firstOrNull()
            m.cameraPosition = CameraPosition.Builder()
                .target(first?.let { LatLng(it.latitude, it.longitude) } ?: LatLng(30.0, 10.0))
                .zoom(if (first != null) 10.0 else 1.5).build()
            m.addOnCameraMoveListener { cameraTick += 1; center = m.cameraPosition.target }
            m.addOnCameraIdleListener { cameraTick += 1; center = m.cameraPosition.target }
            m.addOnMapClickListener { selectedSpotId = null; focus.clearFocus(); false }
            center = m.cameraPosition.target
            map = m
        }
    }
    // OpenFreeMap vector tiles: free, no key. Without a connection the map stays empty, and a
    // spot can still be added at the coordinates under the crosshair.
    LaunchedEffect(map, dark) {
        map?.setStyle("https://tiles.openfreemap.org/styles/${if (dark) "dark" else "liberty"}") { cameraTick += 1 }
    }

    fun flyTo(target: LatLng, zoom: Double) {
        map?.animateCamera(CameraUpdateFactory.newLatLngZoom(target, zoom), 700)
    }

    fun centerOnMe() {
        currentLocation(context) { location ->
            if (location != null) {
                myLocation = location
                flyTo(location, 12.0)
            }
        }
    }
    val askLocation = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { granted ->
        // Refused: explain where to allow it; the first ask was the system's own prompt.
        if (granted.values.any { it }) centerOnMe() else showLocationHelp = true
    }
    fun requestCenter() {
        focus.clearFocus()
        if (hasLocationPermission(context)) centerOnMe()
        else askLocation.launch(arrayOf(Manifest.permission.ACCESS_COARSE_LOCATION, Manifest.permission.ACCESS_FINE_LOCATION))
    }

    // From the welcome screen: go to the phone's position, or open the search.
    LaunchedEffect(request, map) {
        if (request == null || map == null) return@LaunchedEffect
        when (request) {
            MapRequest.LOCATE -> requestCenter()
            MapRequest.SEARCH -> runCatching { searchFocus.requestFocus() }
        }
        onRequestHandled()
    }

    // Suggestions while typing, a moment after the last key.
    LaunchedEffect(query) {
        val trimmed = query.trim()
        if (showingChoice) return@LaunchedEffect
        if (trimmed.length < 2) { results = emptyList(); return@LaunchedEffect }
        delay(400)
        results = search(context, trimmed)
    }
    fun choose(place: Place) {
        focus.clearFocus()
        showingChoice = true
        query = place.title
        results = emptyList()
        flyTo(LatLng(place.latitude, place.longitude), 11.0)
    }

    LaunchedEffect(lastPrefetch, spots.joinToString { "${it.id}${it.waterRaw}${it.speciesRaw}${it.waterTempC}" }) {
        val service = app.forecasts
        val freshIndices = HashMap<String, Double?>()
        val freshOutlooks = HashMap<String, SpotOutlook?>()
        for (spot in spots) {
            // The tide counts at saltwater spots, as on the Forecast tab (saved station first).
            val tide = if (spot.isSalt) service.tideStation(spot.latitude, spot.longitude) else null
            withContext(Dispatchers.Default) {
                freshIndices[spot.id] = currentIndex(spot, tide, service)
                freshOutlooks[spot.id] = outlook(spot, tide, service)
            }
        }
        indices = freshIndices
        outlooks = freshOutlooks
    }

    fun addSpot(name: String, water: WaterType, species: Species) {
        val at = pending ?: center ?: return
        pending = null
        // Checked again here: the count can change while the sheet is open.
        if (!unlimitedSpots && spots.size >= Entitlements.freeSpotLimit) return onPaywall(PaywallContext.SPOTS)
        val isFirst = spots.isEmpty()
        val spot = Spot(
            name = name.trim().ifEmpty { context.getString(R.string.spot_x, spots.size + 1) },
            latitude = at.latitude, longitude = at.longitude, waterRaw = water.raw, speciesRaw = species.raw,
            timeZoneId = com.dautovri.bitecurve.data.SpotTimeZone.zoneAt(context, at.latitude, at.longitude),
        )
        app.store.addSpot(spot)
        // The first spot: straight to its forecast.
        if (isFirst) onFirstSpot(spot)
    }

    Box(Modifier.fillMaxSize()) {
        AndroidView({ mapView }, Modifier.fillMaxSize())

        // Hidden while a spot's card is open: adding is off then, and it would sit on the pin. Under the pins,
        // so a spot's index stays readable when the crosshair is on it.
        if (selectedSpotId == null) Crosshair(center, Modifier.align(Alignment.Center))

        // Pins drawn by Compose over the map, at the screen position of each spot.
        val projection = map?.projection
        if (projection != null) {
            @Suppress("UNUSED_EXPRESSION") cameraTick
            myLocation?.let { me ->
                val p = projection.toScreenLocation(me)
                Box(Modifier.pinAt(p.x, p.y, 9.dp).size(18.dp).shadow(3.dp, CircleShape).background(Color.White, CircleShape).padding(3.dp).background(Color(0xFF2563EB), CircleShape))
            }
            for (spot in spots) {
                val p = projection.toScreenLocation(LatLng(spot.latitude, spot.longitude))
                Box(Modifier.pinAt(p.x, p.y, 17.dp)) {
                    SpotPin(spot.name, indices[spot.id], outlooks[spot.id]?.ranked?.firstOrNull()) {
                        focus.clearFocus()
                        selectedSpotId = spot.id
                    }
                }
            }
        }

        Column(Modifier.statusBarsPadding().padding(horizontal = 16.dp).padding(top = 6.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                SearchBar(query, { showingChoice = false; query = it }, searchFocus, Modifier.weight(1f)) {
                    results.firstOrNull()?.let(::choose)
                }
                val label = stringResource(R.string.my_location)
                Box(
                    Modifier.size(44.dp).clip(CircleShape).background(colors.card.copy(alpha = 0.94f)).border(1.dp, colors.stroke, CircleShape)
                        .clickable(onClick = ::requestCenter).semantics { contentDescription = label; role = Role.Button },
                    contentAlignment = Alignment.Center,
                ) { Icon(Icons.Filled.MyLocation, null, Modifier.size(20.dp), tint = colors.accent) }
            }
            if (results.isNotEmpty() && query.isNotBlank()) {
                Column(Modifier.fillMaxWidth().background(colors.card.copy(alpha = 0.96f), RoundedCornerShape(14.dp)).border(1.dp, colors.stroke, RoundedCornerShape(14.dp))) {
                    results.take(5).forEachIndexed { i, place ->
                        if (i > 0) Hairline()
                        Column(Modifier.fillMaxWidth().clickable { choose(place) }.padding(horizontal = 12.dp, vertical = 8.dp)) {
                            Text(place.title, style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.Medium, color = colors.primaryText)
                            if (place.subtitle.isNotEmpty()) Text(place.subtitle, style = MaterialTheme.typography.bodySmall, color = colors.secondaryText)
                        }
                    }
                }
            }
            if (spots.isNotEmpty()) {
                Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    for (spot in spots) {
                        SpotPill(spot.name, indices[spot.id]) {
                            focus.clearFocus()
                            flyTo(LatLng(spot.latitude, spot.longitude), 11.5)
                            selectedSpotId = spot.id
                        }
                    }
                }
            }
        }

        Box(Modifier.align(Alignment.BottomCenter).padding(16.dp).widthIn(max = Theme.readableWidth)) {
            val selected = spots.firstOrNull { it.id == selectedSpotId }
            if (selected != null) {
                SpeciesNowCard(selected, outlooks[selected.id]) { selectedSpotId = null }
            } else {
                // Out of the way while a spot's card is open, so the map stays visible.
                Button(
                    {
                        val at = center
                        if (!unlimitedSpots && spots.size >= Entitlements.freeSpotLimit) {
                            onPaywall(PaywallContext.SPOTS)
                        } else if (at != null && !lookingUp) {
                            focus.clearFocus()
                            // The place's name and country; the sheet opens after three seconds
                            // at most, with or without an answer.
                            lookingUp = true
                            scope.launch {
                                suggestion = lookup(context, at.latitude, at.longitude)
                                lookingUp = false
                                pending = at
                            }
                        }
                    },
                    Modifier.heightIn(min = 52.dp).shadow(8.dp, CircleShape),
                    // The crosshair position is known once the map has reported its camera.
                    enabled = center != null,
                ) {
                    if (lookingUp) CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp, color = Color.White) else Icon(Icons.Filled.Add, null)
                    Spacer(Modifier.width(8.dp))
                    Text(stringResource(R.string.add_spot_at_crosshair), style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                }
            }
        }
    }

    if (pending != null) {
        AddSpotDialog(suggestion, onDismiss = { pending = null }, onSave = ::addSpot)
    }
    if (showLocationHelp) {
        AlertDialog(
            onDismissRequest = { showLocationHelp = false },
            title = { Text(stringResource(R.string.location_is_off_for_bitecurve)) },
            text = { Text(stringResource(R.string.allow_location_in_settings_to_centre_the_map_on)) },
            confirmButton = {
                TextButton({
                    showLocationHelp = false
                    context.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", context.packageName, null)))
                }) { Text(stringResource(R.string.open_settings)) }
            },
            dismissButton = { TextButton({ showLocationHelp = false }) { Text(stringResource(R.string.cancel)) } },
        )
    }
}

/** Places the content so that the point `anchorY` below its top centre sits at (x, y). */
private fun Modifier.pinAt(x: Float, y: Float, anchorY: androidx.compose.ui.unit.Dp): Modifier = layout { measurable, constraints ->
    val placeable = measurable.measure(constraints.copy(minWidth = 0, minHeight = 0))
    layout(0, 0) { placeable.place((x - placeable.width / 2f).roundToInt(), (y - anchorY.toPx()).roundToInt()) }
}

/**
 * The index of today's best window, as the Forecast tab shows it, from the forecast saved on
 * the phone only (no network from the map). Null without a saved forecast or a window.
 */
private fun currentIndex(spot: Spot, tide: TideStation?, service: ForecastService): Double? {
    val saved = service.cached(spot.latitude, spot.longitude) ?: return null
    val now = nowSeconds()
    val today = startOfDay(now, spot.zone)
    val end = startOfDay(now, spot.zone, 1)
    val points = Forecaster.curve(spot.context(service).copy(tide = tide), saved.hours, today, end, fillMissingWeather = true).filter { it.time < end }
    return Forecaster.bestWindow(points, notBefore = now - 900)?.meanIndex
}

/**
 * Fish ranked by how well the water suits them now, from the saved forecast only. The measured
 * water temperature when there is one, else the saved estimate, else (inland) the last days' air.
 */
private fun outlook(spot: Spot, tide: TideStation?, service: ForecastService): SpotOutlook? {
    val saved = service.cached(spot.latitude, spot.longitude) ?: return null
    val now = nowSeconds()
    var reading = spot.waterReading(service)
    if (reading == null && !spot.isSalt) {
        Terms.estimatedWaterTempC(saved.hours, now)?.let { reading = WaterReading(it, WaterReading.Source.MODELLED) }
    }
    val ranked = Forecaster.speciesNow(spot.context(service).copy(tide = tide), saved.hours, now, reading?.tempC)
    return SpotOutlook(reading, ranked)
}

/** Name, water and fish for a new spot. Android's geocoder cannot tell a lake from the sea, so the water is asked. */
@Composable
private fun AddSpotDialog(suggestion: Suggestion, onDismiss: () -> Unit, onSave: (String, WaterType, Species) -> Unit) {
    val context = LocalContext.current
    val region = suggestion.regionCode ?: Locale.getDefault().country
    var name by remember { mutableStateOf(suggestion.name ?: "") }
    var water by remember { mutableStateOf(WaterType.WARM_FRESHWATER) }
    var species by remember { mutableStateOf(Species.defaultSpecies(region, WaterType.WARM_FRESHWATER)) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.name_this_spot)) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                OutlinedTextField(
                    name, { name = it.take(60) }, label = { Text(stringResource(R.string.name)) }, singleLine = true,
                    keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Words),
                )
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Text(stringResource(R.string.water), Modifier.weight(1f))
                    MenuPicker(stringResource(R.string.water), water.label(context), WaterType.entries.map { it to it.label(context) }) { picked ->
                        water = picked
                        // A water changed to another habitat cannot keep its fish.
                        if (!species.livesIn(picked)) species = Species.defaultSpecies(region, picked)
                    }
                }
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Text(stringResource(R.string.target_species), Modifier.weight(1f))
                    MenuPicker(stringResource(R.string.target_species), species.label(context), Species.choices(water).map { it to it.label(context) }) { species = it }
                }
            }
        },
        confirmButton = { TextButton({ onSave(name, water, species) }) { Text(stringResource(R.string.save)) } },
        dismissButton = { TextButton(onDismiss) { Text(stringResource(R.string.cancel)) } },
    )
}

/** Floating search field over the map. */
@Composable
private fun SearchBar(query: String, onChange: (String) -> Unit, focus: FocusRequester, modifier: Modifier, onSubmit: () -> Unit) {
    val colors = Theme.colors
    val hint = stringResource(R.string.search_lakes_rivers_bays)
    Row(
        modifier.background(colors.card.copy(alpha = 0.94f), RoundedCornerShape(14.dp)).border(1.dp, colors.stroke, RoundedCornerShape(14.dp)).padding(horizontal = 12.dp, vertical = 11.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Icon(Icons.Filled.Search, null, Modifier.size(20.dp), tint = colors.secondaryText)
        BasicTextField(
            query, onChange, Modifier.weight(1f).focusRequester(focus).semantics { contentDescription = hint }, singleLine = true,
            textStyle = TextStyle(color = colors.primaryText, fontSize = 16.sp), cursorBrush = SolidColor(colors.accent),
            keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Words, autoCorrectEnabled = false, imeAction = ImeAction.Search),
            keyboardActions = KeyboardActions(onSearch = { onSubmit() }),
            decorationBox = { inner ->
                Box {
                    if (query.isEmpty()) Text(hint, color = colors.secondaryText, fontSize = 16.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    inner()
                }
            },
        )
        if (query.isNotEmpty()) {
            Icon(Icons.Filled.Cancel, stringResource(R.string.cancel), Modifier.size(20.dp).clip(CircleShape).clickable { onChange("") }, tint = colors.secondaryText)
        }
    }
}

/** Horizontal pill for one saved spot, showing its bite index dot and value when cached. */
@Composable
private fun SpotPill(name: String, index: Double?, onClick: () -> Unit) {
    val colors = Theme.colors
    Row(
        Modifier.clip(CircleShape).background(colors.card.copy(alpha = 0.94f)).border(1.dp, colors.stroke, CircleShape).clickable(onClick = onClick).padding(horizontal = 12.dp, vertical = 7.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        if (index != null) Box(Modifier.size(8.dp).background(colors.bite(index), CircleShape))
        Text(name, style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.Medium, color = colors.primaryText, maxLines = 1)
        if (index != null) Text("${index.roundToInt()}", style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.Bold, color = colors.bite(index))
    }
}

/** Pin for a saved spot: its index in a circle, its name, and the fish the water suits best now. */
@Composable
private fun SpotPin(name: String, index: Double?, best: SpeciesOutlook?, onClick: () -> Unit) {
    val context = LocalContext.current
    val colors = Theme.colors
    val shown = best?.takeIf { it.index >= 50 }
    val state = listOfNotNull(
        index?.let { "${stringResource(R.string.bite_index)} ${it.roundToInt()}" },
        shown?.let { "${stringResource(R.string.best_match_right_now)}: ${it.species.label(context)}" },
    ).joinToString(", ")
    Column(
        Modifier.clickable(onClick = onClick, indication = null, interactionSource = null)
            .clearAndSetSemantics { contentDescription = name; stateDescription = state; role = Role.Button },
        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Box(
            Modifier.size(34.dp).shadow(4.dp, CircleShape).background(Color.White, CircleShape).padding(2.dp)
                .background(if (index != null) colors.bite(index) else colors.accent, CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            if (index != null) Text("${index.roundToInt()}", color = Color.White, fontSize = 14.sp, fontWeight = FontWeight.Bold)
            else FishIcon(Modifier.size(16.dp), Color.White)
        }
        Text(
            name, style = MaterialTheme.typography.labelSmall, fontWeight = FontWeight.SemiBold, color = colors.primaryText, maxLines = 1,
            modifier = Modifier.background(colors.card.copy(alpha = 0.94f), CircleShape).border(0.5.dp, colors.stroke, CircleShape).padding(horizontal = 7.dp, vertical = 3.dp),
        )
        if (shown != null) {
            Row(
                Modifier.background(colors.bite(shown.index), CircleShape).border(1.dp, Color.White.copy(alpha = 0.8f), CircleShape).padding(start = 4.dp, end = 8.dp, top = 2.dp, bottom = 2.dp),
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                shown.species.image()?.let { Image(painterResource(it), null, Modifier.size(30.dp, 16.dp), contentScale = ContentScale.Fit) }
                Text(shown.species.label(context), style = MaterialTheme.typography.labelSmall, fontWeight = FontWeight.Bold, color = Color.White, maxLines = 1)
            }
        }
    }
}

/** Card for a tapped spot: the fish the water suits right now, with their bite index. */
@Composable
private fun SpeciesNowCard(spot: Spot, outlook: SpotOutlook?, onClose: () -> Unit) {
    val context = LocalContext.current
    val colors = Theme.colors
    BiteCard(padding = 14.dp) {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(verticalAlignment = Alignment.Top) {
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(spot.name, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, color = colors.primaryText, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    outlook?.reading?.let { reading ->
                        val degrees = temperature(reading.tempC)
                        val text = when (reading.source) {
                            WaterReading.Source.MEASURED -> stringResource(R.string.water_x_measured, degrees)
                            WaterReading.Source.SATELLITE -> stringResource(R.string.water_about_x_satellite_estimate, degrees)
                            WaterReading.Source.MODELLED -> stringResource(R.string.water_about_x_estimated_from_air, degrees)
                        }
                        Text(text, style = MaterialTheme.typography.bodySmall, color = colors.secondaryText)
                    }
                }
                Icon(Icons.Filled.Cancel, stringResource(R.string.close), Modifier.size(26.dp).clip(CircleShape).clickable(onClick = onClose), tint = colors.secondaryText)
            }
            val ranked = outlook?.ranked ?: emptyList()
            if (ranked.isNotEmpty()) {
                Text(stringResource(R.string.best_match_right_now).uppercase(), style = MaterialTheme.typography.labelMedium, fontWeight = FontWeight.SemiBold, color = colors.secondaryText)
                for (item in ranked.take(3)) {
                    Row(Modifier.semantics(mergeDescendants = true) {}, verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        // A light tile, so dark fish (perch, pike) still read in dark mode.
                        Box(Modifier.size(72.dp, 44.dp).background(if (colors.isDark) Color(0xFFDCE6EC) else Color(0xFFEEF3F6), RoundedCornerShape(10.dp)).padding(horizontal = 6.dp, vertical = 4.dp), contentAlignment = Alignment.Center) {
                            item.species.image()?.let { Image(painterResource(it), null, contentScale = ContentScale.Fit) }
                        }
                        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                            Text(item.species.label(context), style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.SemiBold, color = colors.primaryText)
                            val tint = colors.bite(item.index)
                            Text(
                                biteLabel(context, item.index), style = MaterialTheme.typography.labelSmall, fontWeight = FontWeight.Bold, color = tint,
                                modifier = Modifier.background(tint.copy(alpha = 0.18f), CircleShape).border(0.5.dp, tint.copy(alpha = 0.35f), CircleShape).padding(horizontal = 7.dp, vertical = 2.dp),
                            )
                        }
                        IndexGauge(item.index, 36.dp)
                    }
                }
                Text(stringResource(R.string.conditions_that_suit_each_fish_not_a_survey_of_t), style = MaterialTheme.typography.labelSmall, color = colors.secondaryText)
            } else if (spot.isSalt && outlook != null) {
                // Weather is saved but no sea temperature has arrived for this spot yet.
                Text(stringResource(R.string.no_sea_temperature_for_this_spot_yet_open_it_on), style = MaterialTheme.typography.bodyMedium, color = colors.secondaryText)
            } else {
                Text(stringResource(R.string.open_this_spot_on_the_forecast_tab_to_download_w), style = MaterialTheme.typography.bodyMedium, color = colors.secondaryText)
            }
        }
    }
}

/** Reticle in the centre of the map: a dashed ring with a crosshair and the coordinates below. */
@Composable
private fun Crosshair(center: LatLng?, modifier: Modifier) {
    val colors = Theme.colors
    Box(modifier.clearAndSetSemantics { }, contentAlignment = Alignment.Center) {
        Canvas(Modifier.size(44.dp)) {
            val c = Offset(size.width / 2, size.height / 2)
            for ((color, width) in listOf(Color.Black.copy(alpha = 0.45f) to 3.5.dp.toPx(), Color.White to 1.5.dp.toPx())) {
                drawCircle(color, size.minDimension / 2 - 1.dp.toPx(), c, style = Stroke(width, pathEffect = PathEffect.dashPathEffect(floatArrayOf(4.dp.toPx(), 4.dp.toPx()))))
                drawLine(color, Offset(c.x - 9.dp.toPx(), c.y), Offset(c.x + 9.dp.toPx(), c.y), width)
                drawLine(color, Offset(c.x, c.y - 9.dp.toPx()), Offset(c.x, c.y + 9.dp.toPx()), width)
            }
        }
        if (center != null) {
            val text = "${number(abs(center.latitude), 4)}° ${if (center.latitude >= 0) "N" else "S"}  ${number(abs(center.longitude), 4)}° ${if (center.longitude >= 0) "E" else "W"}"
            Text(
                text, style = MaterialTheme.typography.labelSmall, fontWeight = FontWeight.Medium, color = colors.primaryText, maxLines = 1, softWrap = false,
                modifier = Modifier.padding(top = 80.dp).background(colors.card.copy(alpha = 0.9f), CircleShape).border(0.5.dp, colors.stroke, CircleShape).padding(horizontal = 8.dp, vertical = 3.dp),
            )
        }
    }
}
