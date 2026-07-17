package net.xpossystems.dejavoo_restaurant

import org.json.JSONObject

/**
 * Classification of an iPOSgo SDK transaction result against the request
 * that launched it. (Verbatim port source from repos/dejavoo — keep logic
 * IDENTICAL when porting; only the package name may change.)
 */
enum class ResultKind {
    /** Approved, belongs to this launch, amount matches what we sent. */
    SUCCESS,

    /**
     * Approved, but DvPayLite's echoed refId identifies a DIFFERENT
     * request — the one-behind signature (a cancelled-but-alive Sale got
     * tapped during this launch). Relayed as `unmatched_result`, tagged
     * with its TRUE owner's refId, and must NOT consume this launch's
     * listener: this launch's own result may still arrive.
     */
    UNMATCHED_RESULT,

    /**
     * Approved and the refId matches this launch, but the approved amount
     * differs from what we launched — money moved for the WRONG amount.
     * Relayed as `amount_mismatch`, never as `success`.
     */
    AMOUNT_MISMATCH,

    /**
     * Not a proven approval: respCode != "00" or the spurious-approval
     * triple-gate failed (missing AuthCode / last4).
     */
    FAILED,
}

data class ClassifiedResult(
    val kind: ResultKind,
    val resolvedRefId: String,
    val respCode: String,
    val authCode: String,
    val last4: String,
    val approvedAmount: String,
)

object ResultClassifier {

    fun classify(
        launchedRefId: String?,
        launchedAmount: Double,
        launchedTip: Double,
        transactionResult: JSONObject?,
    ): ClassifiedResult {
        val respCode = transactionResult?.optString("respCode")?.trim().orEmpty()
        val authCode = transactionResult?.optString("authCode")?.trim().orEmpty()
        val last4 = transactionResult?.optString("last_4_digits")?.trim().orEmpty()
        val echoedRef = transactionResult?.optString("refId")?.trim().orEmpty()
        val launched = launchedRefId?.trim().orEmpty()
        val resolvedRef = echoedRef.ifEmpty { launched }
        val approvedAmount =
            transactionResult?.optString("totalAmount")?.trim().orEmpty()

        val isApproved =
            respCode == "00" && authCode.isNotEmpty() && last4.isNotEmpty()
        if (!isApproved) {
            return ClassifiedResult(
                ResultKind.FAILED, resolvedRef, respCode, authCode, last4,
                approvedAmount,
            )
        }

        if (echoedRef.isNotEmpty() && launched.isNotEmpty() &&
            echoedRef != launched
        ) {
            return ClassifiedResult(
                ResultKind.UNMATCHED_RESULT, echoedRef, respCode, authCode,
                last4, approvedAmount,
            )
        }

        val approvedCents =
            approvedAmount.toDoubleOrNull()?.let { Math.round(it * 100) }
        val expectedCents = Math.round((launchedAmount + launchedTip) * 100)
        if (approvedCents != null && approvedCents != expectedCents) {
            return ClassifiedResult(
                ResultKind.AMOUNT_MISMATCH, resolvedRef, respCode, authCode,
                last4, approvedAmount,
            )
        }

        return ClassifiedResult(
            ResultKind.SUCCESS, resolvedRef, respCode, authCode, last4,
            approvedAmount,
        )
    }
}
