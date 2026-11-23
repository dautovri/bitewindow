package com.dautovri.bitecurve

import com.dautovri.bitecurve.ui.SisterApp
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The counterpart of the iOS `CrossPromo.offersOnSpot` tests in StructureTests. */
class CrossPromoTest {
    private fun offers(live: Boolean = true, windowIndex: Double? = 80.0, launches: Int = 9, didOnboard: Boolean = true, done: Boolean = false, anyWindow: Boolean = false) =
        SisterApp.offersOnSpot(live, windowIndex, launches, didOnboard, done, anyWindow)

    @Test fun waitsForTheThirdLaunch() {
        assertFalse(offers(launches = 1))
        assertFalse(offers(launches = 2))
        assertTrue(offers(launches = 3))
    }

    @Test fun onlyOnAStrongBiteWindow() {
        assertTrue(offers(windowIndex = SisterApp.GOOD_WINDOW_INDEX))
        assertFalse(offers(windowIndex = 64.0))
        assertFalse(offers(windowIndex = null))
        assertTrue(offers(windowIndex = 20.0, anyWindow = true))
        assertFalse(offers(windowIndex = null, anyWindow = true))
    }

    @Test fun neverWhileGatedBeforeOnboardingOrOnceDone() {
        // The gate (SisterApp.IS_LIVE) off: nothing, whatever the forecast.
        assertFalse(offers(live = false, windowIndex = 95.0))
        assertFalse(offers(didOnboard = false))
        assertFalse(offers(done = true))
    }

    @Test fun playLinksCarryTheReferrer() {
        assertEquals("market://details?id=com.ruslandautov.houby&referrer=utm_source%3Dbitecurve-app%26utm_medium%3Dxpromo", SisterApp.marketUri)
        assertEquals("https://play.google.com/store/apps/details?id=com.ruslandautov.houby&referrer=utm_source%3Dbitecurve-app%26utm_medium%3Dxpromo", SisterApp.webUri)
    }
}
