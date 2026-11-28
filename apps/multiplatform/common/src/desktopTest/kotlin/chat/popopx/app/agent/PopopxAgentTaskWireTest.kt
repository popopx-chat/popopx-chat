package chat.popopx.app.agent

//
//  PopopxAgentTaskWireTest.kt
//  desktopTest
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//
//  Kotlin twin of apps/ios/PopopxMeshKit/Tests/PopopxMeshKitTests/PopopxAgentTaskWireTests.swift, held
//  to the *same* pinned canonical bodies. A key order, an escape rule or a type choice (`percent` is a
//  string, not a number) that drifts between the two encoders fails here rather than on a device.
//
//  Ed25519 signatures are deterministic on this stack (BouncyCastle) and hedged in CryptoKit, so the
//  Kotlin side pins its own signature and the Swift suite verifies a receipt carrying that exact value.
//

import chat.popopx.common.agent.PopopxAgentReceiptWire
import chat.popopx.common.agent.PopopxAgentTask
import chat.popopx.common.agent.PopopxAgentTaskWire
import chat.popopx.common.crypto.ed25519KeyPair
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class PopopxAgentTaskWireTest {

  private fun approvalTask() = PopopxAgentTask(
    taskId = "task-7f3a",
    kind = PopopxAgentTask.Kind.APPROVAL,
    status = PopopxAgentTask.Status.AWAITING_APPROVAL,
    title = "Run the nightly index rebuild",
    agent = "ops-agent",
    detail = "Rebuilds the search index from today's exports.",
    steps = listOf(
      PopopxAgentTask.Step("Fetch exports", PopopxAgentTask.Step.State.DONE),
      PopopxAgentTask.Step("Rebuild index", PopopxAgentTask.Step.State.ACTIVE),
      PopopxAgentTask.Step("Verify row counts", PopopxAgentTask.Step.State.PENDING),
    ),
    permissions = listOf("filesystem.read:/exports", "network.egress:smp1.popopx.im"),
    retentionZero = true,
    updatedAt = "2026-11-28T09:15:00Z",
  )

  private val approvalBody =
    """{"agent":"ops-agent","detail":"Rebuilds the search index from today's exports.","kind":"approval","permissions":["filesystem.read:/exports","network.egress:smp1.popopx.im"],"retention":"zero","schema":"popopx.agent.task.v1","status":"awaiting_approval","steps":[{"label":"Fetch exports","state":"done"},{"label":"Rebuild index","state":"active"},{"label":"Verify row counts","state":"pending"}],"task":"task-7f3a","title":"Run the nightly index rebuild","updated":"2026-11-28T09:15:00Z"}"""

  private fun choiceTask() = PopopxAgentTask(
    taskId = "task-choice-1",
    kind = PopopxAgentTask.Kind.CHOICE,
    status = PopopxAgentTask.Status.RUNNING,
    title = "Pick a summary length",
    percent = 40,
    choices = listOf(
      PopopxAgentTask.Choice("short", "Short"),
      PopopxAgentTask.Choice("long", "Long"),
    ),
    updatedAt = "2026-11-28T09:20:00Z",
  )

  private val choiceBody =
    """{"choices":[{"id":"short","label":"Short"},{"id":"long","label":"Long"}],"kind":"choice","percent":"40","schema":"popopx.agent.task.v1","status":"running","task":"task-choice-1","title":"Pick a summary length","updated":"2026-11-28T09:20:00Z"}"""

  // MARK: Canonical bytes

  @Test
  fun approvalCardBodyIsPinned() {
    assertEquals(approvalBody, PopopxAgentTaskWire.canonicalBody(approvalTask()).decodeToString())
  }

  @Test
  fun choiceCardBodyIsPinned() {
    assertEquals(choiceBody, PopopxAgentTaskWire.canonicalBody(choiceTask()).decodeToString())
  }

  @Test
  fun wireTextIsMarkerVersionAndBody() {
    assertEquals(
      PopopxAgentTaskWire.MARKER + "v1::" + approvalBody,
      PopopxAgentTaskWire.wireText(approvalTask()),
    )
  }

  // MARK: Round trips

  @Test
  fun approvalCardRoundTrips() {
    val parsed = assertNotNull(PopopxAgentTaskWire.parseVisibleCard(PopopxAgentTaskWire.wireText(approvalTask())))
    assertEquals(approvalTask(), parsed)
    assertTrue(parsed.retentionZero)
    assertNull(parsed.percent)
    assertTrue(parsed.choices.isEmpty())
  }

  @Test
  fun choiceCardRoundTrips() {
    val parsed = assertNotNull(PopopxAgentTaskWire.parseVisibleCard(PopopxAgentTaskWire.wireText(choiceTask())))
    assertEquals(choiceTask(), parsed)
    assertEquals(40, parsed.percent)
    assertFalse(parsed.retentionZero)
  }

  @Test
  fun resultCardRoundTrips() {
    val task = PopopxAgentTask(
      taskId = "task-res-2", kind = PopopxAgentTask.Kind.RESULT,
      status = PopopxAgentTask.Status.COMPLETED, title = "Weekly summary ready",
      result = "42 messages, 3 open threads.", updatedAt = "2026-11-28T11:00:00Z",
    )
    val parsed = assertNotNull(PopopxAgentTaskWire.parseVisibleCard(PopopxAgentTaskWire.wireText(task)))
    assertEquals(task, parsed)
    assertFalse(parsed.isActive)
  }

  @Test
  fun escapesRoundTripAndStayLowercaseHex() {
    val task = PopopxAgentTask(
      taskId = "task-esc", kind = PopopxAgentTask.Kind.PROGRESS,
      status = PopopxAgentTask.Status.RUNNING,
      title = "quote \" back \\ newline \n tab \t ctl \u0001 unicode é 中",
      detail = "slash / stays raw",
    )
    val body = PopopxAgentTaskWire.canonicalBody(task).decodeToString()
    assertTrue(body.contains("ctl \\u0001"))
    assertTrue(body.contains("slash / stays raw"))
    assertFalse(body.contains("\\/"))
    val parsed = assertNotNull(PopopxAgentTaskWire.parseVisibleCard(PopopxAgentTaskWire.wireText(task)))
    assertEquals(task, parsed)
  }

  @Test
  fun humanSentenceBeforeMarkerIsTolerated() {
    val wire = PopopxAgentTaskWire.wireText(choiceTask())
    val parsed = assertNotNull(
      PopopxAgentTaskWire.parseVisibleCard("Here is the question you asked.\n$wire\ntrailing"),
    )
    assertEquals(choiceTask(), parsed)
  }

  @Test
  fun plainTextIsNotACard() {
    assertFalse(PopopxAgentTaskWire.isAgentTaskCard("just a sentence"))
    assertFalse(PopopxAgentTaskWire.isAgentTaskCard(""))
    assertTrue(PopopxAgentTaskWire.isAgentTaskCard(PopopxAgentTaskWire.MARKER + "v1::" + choiceBody))
  }

  // MARK: Refusals

  private fun refuses(body: String) {
    assertNull(PopopxAgentTaskWire.parseVisibleCard(PopopxAgentTaskWire.MARKER + "v1::" + body))
  }

  @Test
  fun refusesUnknownSchemaKindStatus() {
    refuses(choiceBody.replace("\"schema\":\"popopx.agent.task.v1\"", "\"schema\":\"popopx.agent.task.v2\""))
    refuses(choiceBody.replace("\"kind\":\"choice\"", "\"kind\":\"survey\""))
    refuses(choiceBody.replace("\"status\":\"running\"", "\"status\":\"paused\""))
    refuses(choiceBody.replace("\"task\":\"task-choice-1\"", "\"task\":\"bad id\""))
    assertNull(PopopxAgentTaskWire.parseVisibleCard(PopopxAgentTaskWire.MARKER + "v2::" + choiceBody))
  }

  @Test
  fun refusesPercentOutOfRangeOrNonDigits() {
    for (bad in listOf("101", "12x", "-1", "0004", "")) {
      refuses(choiceBody.replace("\"percent\":\"40\"", "\"percent\":\"$bad\""))
    }
  }

  @Test
  fun refusesOversizedCollections() {
    val steps = (0..PopopxAgentTaskWire.MAXIMUM_STEPS)
      .joinToString(",") { "{\"label\":\"s$it\",\"state\":\"done\"}" }
    refuses(choiceBody.replace("\"kind\":\"choice\"", "\"steps\":[$steps],\"kind\":\"choice\""))
    val permissions = (0..PopopxAgentTaskWire.MAXIMUM_PERMISSIONS).joinToString(",") { "\"p$it\"" }
    refuses(choiceBody.replace("\"kind\":\"choice\"", "\"permissions\":[$permissions],\"kind\":\"choice\""))
    val choices = (0..PopopxAgentTaskWire.MAXIMUM_CHOICES)
      .joinToString(",", prefix = "[", postfix = "]") { "{\"id\":\"c$it\",\"label\":\"C$it\"}" }
    refuses(
      choiceBody.replace(
        """[{"id":"short","label":"Short"},{"id":"long","label":"Long"}]""",
        choices,
      ),
    )
  }

  @Test
  fun refusesDuplicateChoiceIdsAndEmptyFields() {
    refuses(choiceBody.replace("\"id\":\"long\"", "\"id\":\"short\""))
    refuses(choiceBody.replace("\"title\":\"Pick a summary length\"", "\"title\":\"\""))
    refuses(choiceBody.replace("\"status\":\"running\"", "\"status\":\"running\",\"agent\":\"\""))
    refuses(choiceBody.replace("\"status\":\"running\"", "\"status\":\"running\",\"detail\":\"\""))
  }

  @Test
  fun refusesOversizedField() {
    val pad = "a".repeat(500)
    refuses(choiceBody.replace("\"title\":\"Pick a summary length\"", "\"title\":\"$pad\""))
  }

  @Test
  fun refusesOversizedLineEvenWhenBodyWouldParse() {
    val body = choiceBody + " ".repeat(9_000)
    assertTrue((PopopxAgentTaskWire.MARKER + "v1::" + body).length > 8_192)
    refuses(body)
  }

  @Test
  fun refusesNonObjectBody() {
    refuses("[]")
    refuses("\"text\"")
    refuses("")
  }

  // MARK: Status transitions (what the home screen reads)

  @Test
  fun activeStatusesAreRunningAndAwaitingApproval() {
    assertTrue(PopopxAgentTask.Status.RUNNING.isActive)
    assertTrue(PopopxAgentTask.Status.AWAITING_APPROVAL.isActive)
    assertFalse(PopopxAgentTask.Status.COMPLETED.isActive)
    assertFalse(PopopxAgentTask.Status.FAILED.isActive)
    assertFalse(PopopxAgentTask.Status.CANCELLED.isActive)
  }

  @Test
  fun statusTransitionSequenceParsesEachStep() {
    var task = choiceTask()
    assertTrue(task.isActive)
    for ((status, active) in listOf(
      PopopxAgentTask.Status.AWAITING_APPROVAL to true,
      PopopxAgentTask.Status.COMPLETED to false,
    )) {
      task = task.copy(status = status, updatedAt = "2026-11-28T12:00:00Z")
      val parsed = assertNotNull(PopopxAgentTaskWire.parseVisibleCard(PopopxAgentTaskWire.wireText(task)))
      assertEquals(status, parsed.status)
      assertEquals(active, parsed.isActive)
      assertEquals("task-choice-1", parsed.taskId)
    }
  }
}

class PopopxAgentReceiptWireTest {

  // Seed 00 01 … 1f. The public key is a pure function of the seed; the signature is pinned because
  // BouncyCastle signs deterministically — the Swift suite verifies the same literal, which is the
  // cross-stack proof that the two envelope builders agree byte for byte.
  private val seed = ByteArray(32) { it.toByte() }
  private val pinnedPublicKey = "A6EHv_POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg"
  private val pinnedSignature =
    "cxab4MNLYp_7US5depjBkeACBXy_JWclgGPQA4pjU3-Vrb79AFr_cKK5xqgbUcsdN_Y2F9pDp6bsrkrqO8yLCw"

  private val approveBody =
    """{"at":"2026-11-28T10:00:00Z","choice":"","decision":"approve","key":"A6EHv_POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg","schema":"popopx.agent.receipt.v1","task":"task-7f3a"}"""

  @Test
  fun approveReceiptIsPinned() {
    val receipt = assertNotNull(
      PopopxAgentReceiptWire.make(
        taskId = "task-7f3a", decision = PopopxAgentReceiptWire.Decision.APPROVE,
        at = "2026-11-28T10:00:00Z", seed = seed,
      ),
    )
    assertEquals(pinnedPublicKey, receipt.publicKey)
    assertEquals(pinnedSignature, receipt.signature)
    assertEquals(
      approveBody,
      PopopxAgentReceiptWire.canonicalBody(
        receipt.taskId, receipt.decision, receipt.choiceId, receipt.at, receipt.publicKey,
      ).decodeToString(),
    )
    assertTrue(PopopxAgentReceiptWire.verify(receipt))
  }

  @Test
  fun receiptRoundTripsThroughWire() {
    val made = assertNotNull(
      PopopxAgentReceiptWire.make(
        taskId = "task-7f3a", decision = PopopxAgentReceiptWire.Decision.DENY,
        at = "2026-11-28T10:05:00Z", seed = seed,
      ),
    )
    val text = PopopxAgentReceiptWire.wireText(made)
    assertTrue(PopopxAgentReceiptWire.isReceiptText(text))
    val parsed = assertNotNull(PopopxAgentReceiptWire.parseReceipt("\n  $text  \n"))
    assertEquals(made, parsed)
    assertTrue(PopopxAgentReceiptWire.verify(parsed))
  }

  @Test
  fun chooseReceiptCarriesChoiceId() {
    val made = assertNotNull(
      PopopxAgentReceiptWire.make(
        taskId = "task-choice-1", decision = PopopxAgentReceiptWire.Decision.CHOOSE,
        choiceId = "short", at = "2026-11-28T10:10:00Z", seed = seed,
      ),
    )
    val parsed = assertNotNull(PopopxAgentReceiptWire.parseReceipt(PopopxAgentReceiptWire.wireText(made)))
    assertEquals("short", parsed.choiceId)
    assertTrue(PopopxAgentReceiptWire.verify(parsed))
    assertNull(
      PopopxAgentReceiptWire.make(
        taskId = "task-choice-1", decision = PopopxAgentReceiptWire.Decision.CHOOSE,
        at = "x", seed = seed,
      ),
    )
    assertNull(
      PopopxAgentReceiptWire.make(
        taskId = "bad id", decision = PopopxAgentReceiptWire.Decision.APPROVE,
        at = "x", seed = seed,
      ),
    )
  }

  @Test
  fun tamperedReceiptFailsVerification() {
    val made = assertNotNull(
      PopopxAgentReceiptWire.make(
        taskId = "task-7f3a", decision = PopopxAgentReceiptWire.Decision.APPROVE,
        at = "2026-11-28T10:00:00Z", seed = seed,
      ),
    )
    assertFalse(PopopxAgentReceiptWire.verify(made.copy(decision = PopopxAgentReceiptWire.Decision.DENY)))
    assertFalse(PopopxAgentReceiptWire.verify(made.copy(at = "2026-11-28T10:00:01Z")))
    assertFalse(PopopxAgentReceiptWire.verify(made.copy(taskId = "task-7f3b")))
    assertFalse(PopopxAgentReceiptWire.verify(made.copy(signature = pinnedPublicKey)))
  }

  @Test
  fun parseRefusesInconsistentDecision() {
    val chooseWithoutChoice = approveBody.replace("\"decision\":\"approve\"", "\"decision\":\"choose\"")
    assertNull(PopopxAgentReceiptWire.parseReceipt("::POPOPX_AGENT_RCPT::v1::$chooseWithoutChoice"))
    val approveWithChoice = approveBody.replace("\"choice\":\"\"", "\"choice\":\"short\"")
    assertNull(PopopxAgentReceiptWire.parseReceipt("::POPOPX_AGENT_RCPT::v1::$approveWithChoice"))
  }

  @Test
  fun isReceiptTextIsWholeStringOnly() {
    assertFalse(PopopxAgentReceiptWire.isReceiptText("hello ::POPOPX_AGENT_RCPT::v1::{}"))
    assertFalse(PopopxAgentReceiptWire.isReceiptText("::POPOPX_AGENT::v1::{}"))
    assertFalse(PopopxAgentReceiptWire.isReceiptText(""))
    assertTrue(PopopxAgentReceiptWire.isReceiptText("  \n::POPOPX_AGENT_RCPT::v1::{}"))
  }

  @Test
  fun taskCardIsNotAReceipt() {
    val card = PopopxAgentTaskWire.wireText(
      PopopxAgentTask(taskId = "t", kind = PopopxAgentTask.Kind.RESULT,
        status = PopopxAgentTask.Status.COMPLETED, title = "Done"),
    )
    assertFalse(PopopxAgentReceiptWire.isReceiptText(card))
    assertTrue(PopopxAgentTaskWire.isAgentTaskCard(card))
  }

  @Test
  fun foreignSignerInterop() {
    // A second, unrelated keypair must not be able to vouch for a body signed by the first: this is
    // the same check as `tamperedReceiptFailsVerification` from the other direction.
    val (privateKey, publicKey) = ed25519KeyPair()
    val receipt = assertNotNull(
      PopopxAgentReceiptWire.make(
        taskId = "task-7f3a", decision = PopopxAgentReceiptWire.Decision.APPROVE,
        at = "2026-11-28T10:00:00Z", seed = privateKey,
      ),
    )
    assertTrue(PopopxAgentReceiptWire.verify(receipt))
    assertEquals(
      chat.popopx.common.crypto.base64UrlEncode(publicKey),
      receipt.publicKey,
    )
    assertFalse(PopopxAgentReceiptWire.verify(receipt.copy(publicKey = pinnedPublicKey)))
  }
}
