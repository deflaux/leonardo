package org.broadinstitute.dsde.workbench.leonardo
package monitor

import org.scalatest.flatspec.AnyFlatSpec
import io.circe.parser.decode
import org.broadinstitute.dsde.workbench.google2.ZoneName
import org.broadinstitute.dsde.workbench.leonardo.monitor.NonLeoMessageSubscriber.nonLeoMessageDecoder
import org.broadinstitute.dsde.workbench.model.google.GoogleProject

class NonLeoMessageSubscriberSpec extends AnyFlatSpec with LeonardoTestSuite {
  it should "decode NonLeoMessage properly" in {
    val jsonString =
      """
        |{
        |  "insertId": "1b6nno4f2ybl2l",
        |  "logName": "projects/general-dev-billing-account/logs/cryptomining",
        |  "receiveTimestamp": "2020-11-13T17:43:14.851633055Z",
        |  "resource": {
        |    "labels": {
        |      "instance_id": "715447017152936528",
        |      "project_id": "general-dev-billing-account",
        |      "zone": "us-central1-a"
        |    },
        |    "type": "gce_instance"
        |  },
        |  "severity": "ERROR",
        |  "textPayload": "CRYPTOMINING_DETECTED\n",
        |  "timestamp": "2020-11-13T17:43:15.135933929Z"
        |}
        |""".stripMargin
    val expectedResult = NonLeoMessage.CryptoMining(
      "CRYPTOMINING_DETECTED\n",
      GoogleResource(
        GoogleLabels(715447017152936528L, GoogleProject("general-dev-billing-account"), ZoneName("us-central1-a"))
      )
    )
    decode[NonLeoMessage](jsonString) shouldBe Right(expectedResult)
  }
}
