package com.dautovri.bitecurve

import android.content.Context
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters

/** Background refresh of the saved forecasts (see `BiteCurveApp.scheduleBackgroundRefresh`). */
class RefreshWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        val app = applicationContext as BiteCurveApp
        val (saved, total) = app.refresh()
        return if (total > 0 && saved == 0) Result.retry() else Result.success()
    }
}
