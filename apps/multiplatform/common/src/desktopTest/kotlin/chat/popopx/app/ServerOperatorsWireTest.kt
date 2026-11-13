package com.popopxchat.popopx

import chat.popopx.common.model.OperatorTag
import chat.popopx.common.model.ServerOperatorConditionsDetail
import chat.popopx.common.model.UsageConditionsAction
import chat.popopx.common.model.json
import kotlin.test.Test
import kotlin.test.assertEquals

class ServerOperatorsWireTest {
  @Test
  fun decodesTheOperatorTagTheCoreEncodes() {
    val detail = json.decodeFromString<ServerOperatorConditionsDetail>(CORE_SERVER_OPERATOR_CONDITIONS)
    assertEquals(OperatorTag.SIMPLEX, detail.serverOperators.single().operatorTag)
    val review = detail.conditionsAction as UsageConditionsAction.Review
    assertEquals(OperatorTag.SIMPLEX, review.operators.single().operatorTag)
  }
}

// The "conditions" value of a real serverOperatorConditions response, byte for byte from CI run 43397744144's app.log.
// The tag is spelled by the core (src/Popopx/Chat/Operators.hs textEncode OTSimplex = "simplex"), so this fails when
// only the Kotlin @SerialName is rebranded - the one-sided rename no identifier audit can see.
private const val CORE_SERVER_OPERATOR_CONDITIONS = """{"serverOperators":[{"operatorId":1,"operatorTag":"simplex","tradeName":"SimpleX Chat","legalName":"SimpleX Chat Ltd","serverDomains":["simplex.im"],"conditionsAcceptance":{"type":"required"},"enabled":true,"smpRoles":{"storage":true,"proxy":true,"names":true},"xftpRoles":{"storage":true,"proxy":true,"names":false}}],"currentConditions":{"conditionsId":2,"conditionsCommit":"5cb85b913989aa4dc618a0a47ffb9a758e44f375","createdAt":"2026-11-13T09:08:35.663740443Z"},"conditionsAction":{"type":"review","operators":[{"operatorId":1,"operatorTag":"simplex","tradeName":"SimpleX Chat","legalName":"SimpleX Chat Ltd","serverDomains":["simplex.im"],"conditionsAcceptance":{"type":"required"},"enabled":true,"smpRoles":{"storage":true,"proxy":true,"names":true},"xftpRoles":{"storage":true,"proxy":true,"names":false}}],"deadline":"2026-12-14T09:08:35.806255791Z","showNotice":true}}"""
