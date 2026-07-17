package net.xpossystems.dejavoo_restaurant

import android.content.Intent
import android.os.Bundle
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.contract.ActivityResultContracts
import com.denovo.app.invokeiposgo.launcher.IntentApplication
import com.denovo.app.invokeiposgo.listeners.TransactionListener
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.util.Locale
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Hosts the `xpos/dvpay` MethodChannel that drives DvPayLite (Dejavoo's
 * payment app on this same terminal) through the invoke-dvpay-lite SDK.
 *
 * FlutterFragmentActivity, not FlutterActivity: the SDK launches DvPayLite
 * through an androidx ActivityResultLauncher, which needs a ComponentActivity
 * and must be registered before the activity is started (so: in onCreate).
 *
 * Channel methods (all async, one transaction in flight at a time — a second
 * call while busy errors with code 'BUSY'):
 *   sale    {amount: double, tip: double, refId: String}
 *   voidTxn {amount: double, refId: String}
 *   status  {refId: String}
 * Every method completes with the same map shape:
 *   {kind, status, statusCode, authCode, last4, amount, resolvedRefId,
 *    message, cardType, entryType, launched}
 */
class MainActivity : FlutterFragmentActivity() {

    private companion object {
        const val CHANNEL = "xpos/dvpay"
    }

    private lateinit var intentApplication: IntentApplication
    private lateinit var activityLauncher: ActivityResultLauncher<Intent>

    /** One DvPayLite transaction in flight at a time. */
    private val busy = AtomicBoolean(false)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        intentApplication = IntentApplication(this)
        activityLauncher = registerForActivityResult(
            ActivityResultContracts.StartActivityForResult(),
        ) { result ->
            // Feed DvPayLite's activity result back into the SDK; the outcome
            // is then delivered through the TransactionListener callbacks.
            intentApplication.handleResultCallBack(result)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                val refId = call.argument<String>("refId")?.trim().orEmpty()
                when (call.method) {
                    "sale" -> {
                        val amount = call.argument<Number>("amount")?.toDouble()
                        val tip = call.argument<Number>("tip")?.toDouble() ?: 0.0
                        if (amount == null || refId.isEmpty()) {
                            result.error("BAD_ARGS", "sale requires amount and refId", null)
                        } else {
                            runTransaction(
                                result, refId, amount, tip,
                                saleRequest(amount, tip, refId), statusLookup = false,
                            )
                        }
                    }
                    "voidTxn" -> {
                        val amount = call.argument<Number>("amount")?.toDouble()
                        if (amount == null || refId.isEmpty()) {
                            result.error("BAD_ARGS", "voidTxn requires amount and refId", null)
                        } else {
                            runTransaction(
                                result, refId, amount, 0.0,
                                voidRequest(amount, refId), statusLookup = false,
                            )
                        }
                    }
                    "status" -> {
                        if (refId.isEmpty()) {
                            result.error("BAD_ARGS", "status requires refId", null)
                        } else {
                            runTransaction(
                                result, refId, 0.0, 0.0,
                                statusRequest(refId), statusLookup = true,
                            )
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    // ------------------------------------------------------------- requests

    /** Amounts always cross to DvPayLite as 2-decimal strings, never doubles. */
    private fun money(v: Double): String = String.format(Locale.US, "%.2f", v)

    private fun customUi(): JSONObject = JSONObject()
        .put("fontFamily", "Inter")
        .put("primaryColor", "FF650D")
        .put("secondaryColor", "000000")
        .put("negativeButtonColor", "C62828")

    private fun saleRequest(amount: Double, tip: Double, refId: String): JSONObject {
        val json = JSONObject()
            .put("type", "SALE")
            .put("paymentType", "CREDIT")
            .put("amount", money(amount))
        if (tip > 0) json.put("tip", money(tip))
        return json
            .put("applicationType", "DVPAYLITE")
            .put("refId", refId)
            .put("receiptType", "No")
            .put("isTxnStatusScreenRequired", "No")
            .put("customUI", customUi())
    }

    private fun voidRequest(amount: Double, refId: String): JSONObject = JSONObject()
        .put("type", "VOID")
        .put("paymentType", "CREDIT")
        .put("amount", money(amount))
        .put("applicationType", "DVPAYLITE")
        .put("refId", refId)
        .put("receiptType", "No")
        .put("isTxnStatusScreenRequired", "No")
        .put("customUI", customUi())

    private fun statusRequest(refId: String): JSONObject = JSONObject()
        .put("type", "STATUS")
        .put("applicationType", "DVPAYLITE")
        .put("refId", refId)
        .put("receiptType", "No")
        .put("isTxnStatusScreenRequired", "No")

    // ---------------------------------------------------------- transaction

    private fun runTransaction(
        result: MethodChannel.Result,
        refId: String,
        amount: Double,
        tip: Double,
        request: JSONObject,
        statusLookup: Boolean,
    ) {
        if (!busy.compareAndSet(false, true)) {
            result.error("BUSY", "A DvPayLite transaction is already in progress", null)
            return
        }
        val failStatus = if (statusLookup) "not_found" else "failed"
        // DvPayLite/SDK callbacks can fire more than once for one launch —
        // complete the Dart result exactly once, then free the gate. (This
        // also covers UNMATCHED_RESULT: it completes with status
        // 'unmatched_result' and frees the gate — no launch queue in this
        // app, so nothing waits behind it.)
        val completed = AtomicBoolean(false)
        fun finish(payload: Map<String, Any?>) {
            if (!completed.compareAndSet(false, true)) return
            busy.set(false)
            runOnUiThread { result.success(payload) }
        }

        intentApplication.setTransactionListener(object : TransactionListener {
            override fun onApplicationLaunched(launchData: JSONObject?) {
                // DvPayLite is up; the transaction outcome is still to come.
            }

            override fun onApplicationLaunchFailed(errorResult: JSONObject) {
                finish(errorMap(
                    status = failStatus,
                    statusCode = "LAUNCH_FAILED",
                    message = errorResult.optString("error_message").trim()
                        .ifEmpty { "DvPayLite could not be launched" },
                    refId = refId,
                ))
            }

            override fun onTransactionSuccess(transactionResult: JSONObject?) {
                finish(
                    if (statusLookup) statusMap(refId, transactionResult)
                    else classifiedMap(refId, amount, tip, transactionResult),
                )
            }

            override fun onTransactionFailed(errorResult: JSONObject) {
                val code = errorResult.optString("error_code").trim()
                    .ifEmpty { errorResult.optString("respCode").trim() }
                val message = errorResult.optString("error_message").trim()
                    .ifEmpty { errorResult.optString("respMsg").trim() }
                finish(errorMap(
                    status = failStatus,
                    statusCode = code,
                    message = message,
                    refId = refId,
                ))
            }
        })

        try {
            intentApplication.performTransaction(request, activityLauncher)
        } catch (e: Exception) {
            finish(errorMap(
                status = failStatus,
                statusCode = "LAUNCH_FAILED",
                message = e.message ?: "Could not start DvPayLite",
                refId = refId,
            ))
        }
    }

    // -------------------------------------------------------------- results

    private fun entryType(payload: JSONObject?): String {
        val entry = payload?.optString("entry_type")?.trim().orEmpty()
        return entry.ifEmpty { payload?.optString("transaction_mode")?.trim().orEmpty() }
    }

    /** SALE / VOID outcome: classify against what this launch asked for. */
    private fun classifiedMap(
        launchedRefId: String,
        amount: Double,
        tip: Double,
        payload: JSONObject?,
    ): Map<String, Any?> {
        val c = ResultClassifier.classify(launchedRefId, amount, tip, payload)
        val status = when (c.kind) {
            ResultKind.SUCCESS -> "success"
            ResultKind.AMOUNT_MISMATCH -> "amount_mismatch"
            ResultKind.UNMATCHED_RESULT -> "unmatched_result"
            ResultKind.FAILED -> "failed"
        }
        return mapOf(
            "kind" to c.kind.name,
            "status" to status,
            "statusCode" to c.respCode,
            "authCode" to c.authCode,
            "last4" to c.last4,
            "amount" to c.approvedAmount,
            "resolvedRefId" to c.resolvedRefId,
            "message" to payload?.optString("respMsg")?.trim().orEmpty(),
            "cardType" to payload?.optString("card_type")?.trim().orEmpty(),
            "entryType" to entryType(payload),
            "launched" to launchedRefId,
        )
    }

    /**
     * STATUS (read-only reconcile) outcome: approved only on the triple gate
     * respCode=="00" && authCode && last4 — anything else is 'not_found'.
     */
    private fun statusMap(launchedRefId: String, payload: JSONObject?): Map<String, Any?> {
        val respCode = payload?.optString("respCode")?.trim().orEmpty()
        val authCode = payload?.optString("authCode")?.trim().orEmpty()
        val last4 = payload?.optString("last_4_digits")?.trim().orEmpty()
        val echoedRef = payload?.optString("refId")?.trim().orEmpty()
        val approved = respCode == "00" && authCode.isNotEmpty() && last4.isNotEmpty()
        return mapOf(
            "kind" to if (approved) "SUCCESS" else "FAILED",
            "status" to if (approved) "success" else "not_found",
            "statusCode" to respCode,
            "authCode" to authCode,
            "last4" to last4,
            "amount" to payload?.optString("totalAmount")?.trim().orEmpty(),
            "resolvedRefId" to echoedRef.ifEmpty { launchedRefId },
            "message" to payload?.optString("respMsg")?.trim().orEmpty(),
            "cardType" to payload?.optString("card_type")?.trim().orEmpty(),
            "entryType" to entryType(payload),
            "launched" to launchedRefId,
        )
    }

    private fun errorMap(
        status: String,
        statusCode: String,
        message: String,
        refId: String,
    ): Map<String, Any?> = mapOf(
        "kind" to "FAILED",
        "status" to status,
        "statusCode" to statusCode,
        "authCode" to "",
        "last4" to "",
        "amount" to "",
        "resolvedRefId" to refId,
        "message" to message,
        "cardType" to "",
        "entryType" to "",
        "launched" to refId,
    )
}
