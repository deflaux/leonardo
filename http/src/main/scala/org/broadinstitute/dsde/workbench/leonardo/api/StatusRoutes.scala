package org.broadinstitute.dsde.workbench.leonardo
package http
package api

import akka.http.scaladsl.server
import akka.http.scaladsl.server.Directives._
import org.broadinstitute.dsde.workbench.leonardo.http.service.StatusService
import akka.http.scaladsl.marshallers.sprayjson.SprayJsonSupport._
import akka.http.scaladsl.model.StatusCodes
import spray.json.{JsObject, JsString}
import org.broadinstitute.dsde.workbench.util.health.StatusJsonSupport._
import scala.concurrent.ExecutionContext

object BuildTimeVersion {
  val version = Option(getClass.getPackage.getImplementationVersion)
  val versionJson = JsObject(Map("version" -> JsString(version.getOrElse("n/a"))))
}

class StatusRoutes(statusService: StatusService)(implicit executionContext: ExecutionContext) {
  val route: server.Route =
    pathPrefix("status") {
      pathEndOrSingleSlash {
        get {
          complete(statusService.getStatus().map { statusResponse =>
            val httpStatus = if (statusResponse.ok) StatusCodes.OK else StatusCodes.InternalServerError
            httpStatus -> statusResponse
          })
        }
      }
    } ~
      pathPrefix("version") {
        pathEndOrSingleSlash {
          get {
            complete((StatusCodes.OK, BuildTimeVersion.versionJson))
          }
        }
      }
}
