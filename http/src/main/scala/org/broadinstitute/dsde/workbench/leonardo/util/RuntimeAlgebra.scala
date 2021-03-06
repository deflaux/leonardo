package org.broadinstitute.dsde.workbench.leonardo
package util

import java.time.Instant

import cats.mtl.Ask
import com.google.cloud.compute.v1.Operation
import monocle.Prism
import org.broadinstitute.dsde.workbench.google2.{DiskName, MachineTypeName, ZoneName}
import org.broadinstitute.dsde.workbench.leonardo.config._
import org.broadinstitute.dsde.workbench.leonardo.monitor.LeoPubsubMessage.CreateRuntimeMessage
import org.broadinstitute.dsde.workbench.leonardo.monitor.RuntimeConfigInCreateRuntimeMessage
import org.broadinstitute.dsde.workbench.model.google.{GcsBucketName, GoogleProject, ServiceAccountKey}
import org.broadinstitute.dsde.workbench.model.{TraceId, WorkbenchEmail}

import scala.concurrent.duration.FiniteDuration

/**
 * Defines an algebra for manipulating Leo Runtimes.
 * Currently has interpreters for Dataproc and GCE.
 */
trait RuntimeAlgebra[F[_]] {
  def createRuntime(params: CreateRuntimeParams)(
    implicit ev: Ask[F, AppContext]
  ): F[CreateGoogleRuntimeResponse]
  def getRuntimeStatus(params: GetRuntimeStatusParams)(implicit ev: Ask[F, TraceId]): F[RuntimeStatus]
  def deleteRuntime(params: DeleteRuntimeParams)(implicit ev: Ask[F, TraceId]): F[Option[Operation]]
  def finalizeDelete(params: FinalizeDeleteParams)(implicit ev: Ask[F, TraceId]): F[Unit]
  def stopRuntime(params: StopRuntimeParams)(implicit ev: Ask[F, AppContext]): F[Option[Operation]]
  def startRuntime(params: StartRuntimeParams)(implicit ev: Ask[F, AppContext]): F[Unit]
  def updateMachineType(params: UpdateMachineTypeParams)(implicit ev: Ask[F, TraceId]): F[Unit]
  def updateDiskSize(params: UpdateDiskSizeParams)(implicit ev: Ask[F, TraceId]): F[Unit]
  def resizeCluster(params: ResizeClusterParams)(implicit ev: Ask[F, TraceId]): F[Unit]
}

// Parameters
final case class CreateRuntimeParams(id: Long,
                                     runtimeProjectAndName: RuntimeProjectAndName,
                                     serviceAccountInfo: WorkbenchEmail,
                                     asyncRuntimeFields: Option[AsyncRuntimeFields],
                                     auditInfo: AuditInfo,
                                     jupyterUserScriptUri: Option[UserScriptPath],
                                     jupyterStartUserScriptUri: Option[UserScriptPath],
                                     userJupyterExtensionConfig: Option[UserJupyterExtensionConfig],
                                     defaultClientId: Option[String],
                                     runtimeImages: Set[RuntimeImage],
                                     scopes: Set[String],
                                     welderEnabled: Boolean,
                                     customEnvironmentVariables: Map[String, String],
                                     runtimeConfig: RuntimeConfigInCreateRuntimeMessage)
object CreateRuntimeParams {
  def fromCreateRuntimeMessage(message: CreateRuntimeMessage): CreateRuntimeParams =
    CreateRuntimeParams(
      message.runtimeId,
      message.runtimeProjectAndName,
      message.serviceAccountInfo,
      message.asyncRuntimeFields,
      message.auditInfo,
      message.jupyterUserScriptUri,
      message.jupyterStartUserScriptUri,
      message.userJupyterExtensionConfig,
      message.defaultClientId,
      message.runtimeImages,
      message.scopes,
      message.welderEnabled,
      message.customEnvironmentVariables,
      message.runtimeConfig
    )
}
final case class CreateGoogleRuntimeResponse(asyncRuntimeFields: AsyncRuntimeFields,
                                             initBucket: GcsBucketName,
                                             serviceAccountKey: Option[ServiceAccountKey],
                                             customImage: CustomImage)
final case class GetRuntimeStatusParams(googleProject: GoogleProject,
                                        runtimeName: RuntimeName,
                                        zoneName: Option[ZoneName]) // zoneName is only needed for GCE
final case class DeleteRuntimeParams(runtime: Runtime)
final case class FinalizeDeleteParams(runtime: Runtime)
final case class StopRuntimeParams(runtime: Runtime, dataprocConfig: Option[RuntimeConfig.DataprocConfig], now: Instant)
final case class StartRuntimeParams(runtime: Runtime, initBucket: GcsBucketName)
final case class UpdateMachineTypeParams(runtime: Runtime, machineType: MachineTypeName, now: Instant)

sealed trait UpdateDiskSizeParams extends Product with Serializable
object UpdateDiskSizeParams {
  final case class Dataproc(diskSize: DiskSize, masterDataprocInstance: DataprocInstance) extends UpdateDiskSizeParams
  final case class Gce(googleProject: GoogleProject, diskName: DiskName, diskSize: DiskSize)
      extends UpdateDiskSizeParams

  val dataprocPrism = Prism[UpdateDiskSizeParams, Dataproc] {
    case x: Dataproc => Some(x)
    case _           => None
  }(identity)

  val gcePrism = Prism[UpdateDiskSizeParams, Gce] {
    case x: Gce => Some(x)
    case _      => None
  }(identity)
}

final case class ResizeClusterParams(runtime: Runtime, numWorkers: Option[Int], numPreemptibles: Option[Int])

// Configurations
sealed trait RuntimeInterpreterConfig {
  def welderConfig: WelderConfig
  def imageConfig: ImageConfig
  def proxyConfig: ProxyConfig
  def clusterResourcesConfig: ClusterResourcesConfig
  def clusterFilesConfig: SecurityFilesConfig
  def runtimeCreationTimeout: FiniteDuration
}
object RuntimeInterpreterConfig {
  final case class DataprocInterpreterConfig(dataprocConfig: DataprocConfig,
                                             groupsConfig: GoogleGroupsConfig,
                                             welderConfig: WelderConfig,
                                             imageConfig: ImageConfig,
                                             proxyConfig: ProxyConfig,
                                             vpcConfig: VPCConfig,
                                             clusterResourcesConfig: ClusterResourcesConfig,
                                             clusterFilesConfig: SecurityFilesConfig,
                                             runtimeCreationTimeout: FiniteDuration)
      extends RuntimeInterpreterConfig

  final case class GceInterpreterConfig(gceConfig: GceConfig,
                                        welderConfig: WelderConfig,
                                        imageConfig: ImageConfig,
                                        proxyConfig: ProxyConfig,
                                        vpcConfig: VPCConfig,
                                        clusterResourcesConfig: ClusterResourcesConfig,
                                        clusterFilesConfig: SecurityFilesConfig,
                                        runtimeCreationTimeout: FiniteDuration)
      extends RuntimeInterpreterConfig
}
