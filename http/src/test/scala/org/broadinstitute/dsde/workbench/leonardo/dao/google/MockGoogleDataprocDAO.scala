package org.broadinstitute.dsde.workbench.google.mock

import java.util.UUID

import org.broadinstitute.dsde.workbench.google2.DataprocRole.{Master, SecondaryWorker, Worker}
import org.broadinstitute.dsde.workbench.google2.{DataprocRole, InstanceName, OperationName, ZoneName}
import org.broadinstitute.dsde.workbench.leonardo._
import org.broadinstitute.dsde.workbench.leonardo.dao.google.{CreateClusterConfig, GoogleDataprocDAO}
import org.broadinstitute.dsde.workbench.model.google._

import scala.collection.concurrent.TrieMap
import scala.collection.mutable
import scala.concurrent.Future

class MockGoogleDataprocDAO(ok: Boolean = true) extends GoogleDataprocDAO {

  val clusters: mutable.Map[RuntimeName, GoogleOperation] = new TrieMap()
  val instances: mutable.Map[RuntimeName, mutable.Map[DataprocRole, Set[DataprocInstanceKey]]] = new TrieMap()
  val badClusterName = RuntimeName("badCluster")
  val errorClusterName1 = RuntimeName("erroredCluster1")
  val errorClusterName2 = RuntimeName("erroredCluster2")
  val errorClusters = Seq(errorClusterName1, errorClusterName2)

  private def googleID = UUID.randomUUID()

  override def createCluster(config: CreateClusterConfig): Future[GoogleOperation] =
    if (config.projectAndName.runtimeName == badClusterName) {
      Future.failed(new Exception("bad cluster!"))
    } else {
      val operation = GoogleOperation(OperationName("op-name"), GoogleId(UUID.randomUUID().toString))
      clusters += config.projectAndName.runtimeName -> operation

      val masterInstance = Set(
        DataprocInstanceKey(config.projectAndName.googleProject, ZoneName("my-zone"), InstanceName("master-instance"))
      )
      val workerInstances =
        List
          .tabulate(config.machineConfig.numberOfWorkers) { i =>
            DataprocInstanceKey(config.projectAndName.googleProject,
                                ZoneName("my-zone"),
                                InstanceName(s"worker-instance-$i"))
          }
          .toSet
      val secondaryWorkerInstances = config.machineConfig.numberOfPreemptibleWorkers
        .map(num =>
          List
            .tabulate(num) { i =>
              DataprocInstanceKey(config.projectAndName.googleProject,
                                  ZoneName("my-zone"),
                                  InstanceName(s"secondary-worker-instance-$i"))
            }
            .toSet
        )
        .getOrElse(Set.empty)
      instances += config.projectAndName.runtimeName -> mutable.Map(Master -> masterInstance,
                                                                    Worker -> workerInstances,
                                                                    SecondaryWorker -> secondaryWorkerInstances)
      Future.successful(operation)
    }

  override def deleteCluster(googleProject: GoogleProject, clusterName: RuntimeName): Future[Unit] = {
    clusters.remove(clusterName)
    Future.successful(())
  }

  override def getClusterStatus(googleProject: GoogleProject,
                                clusterName: RuntimeName): Future[Option[DataprocClusterStatus]] =
    Future.successful {
      if (clusters.contains(clusterName) && errorClusters.contains(clusterName)) Some(DataprocClusterStatus.Error)
      else if (clusters.contains(clusterName)) Some(DataprocClusterStatus.Running)
      else Some(DataprocClusterStatus.Unknown)
    }

  override def listClusters(googleProject: GoogleProject): Future[List[UUID]] =
    if (!ok) Future.failed(new Exception("bad project"))
    else Future.successful(Stream.continually(UUID.randomUUID).take(5).toList)

  override def getClusterMasterInstance(googleProject: GoogleProject,
                                        clusterName: RuntimeName): Future[Option[DataprocInstanceKey]] =
    Future.successful {
      if (clusters.contains(clusterName))
        Some(DataprocInstanceKey(googleProject, ZoneName("my-zone"), InstanceName("master-instance")))
      else None
    }

  override def getClusterErrorDetails(operationName: Option[OperationName]): Future[Option[RuntimeErrorDetails]] =
    Future.successful(None)

  override def getClusterStagingBucket(googleProject: GoogleProject,
                                       clusterName: RuntimeName): Future[Option[GcsBucketName]] =
    Future.successful(Some(GcsBucketName("staging-bucket")))

  override def resizeCluster(googleProject: GoogleProject,
                             clusterName: RuntimeName,
                             numWorkers: Option[Int],
                             numPreemptibles: Option[Int]): Future[Unit] = {
    if (numWorkers.isDefined) {
      val workerInstances = numWorkers
        .map(num =>
          List
            .tabulate(num) { i =>
              DataprocInstanceKey(googleProject, ZoneName("my-zone"), InstanceName(s"worker-instance-$i"))
            }
            .toSet
        )
        .getOrElse(Set.empty)
      val existingSecondaryInstances = instances.get(clusterName).flatMap(_.get(SecondaryWorker))
      val existingMasterInstance = instances.get(clusterName).flatMap(_.get(Master))

      instances += (clusterName -> mutable.Map(Master -> existingMasterInstance.getOrElse(Set.empty),
                                               Worker -> workerInstances,
                                               SecondaryWorker -> existingSecondaryInstances.getOrElse(Set.empty)))
    }

    val secondaryWorkerInstances = numPreemptibles
      .map(num =>
        List
          .tabulate(num) { i =>
            DataprocInstanceKey(googleProject, ZoneName("my-zone"), InstanceName(s"secondary-worker-instance-$i"))
          }
          .toSet
      )
      .getOrElse(Set.empty)
    val existingWorkerInstances = instances.get(clusterName).flatMap(_.get(Worker))
    val existingMasterInstance = instances.get(clusterName).flatMap(_.get(Master))

    instances += (clusterName -> mutable.Map(Master -> existingMasterInstance.getOrElse(Set.empty),
                                             Worker -> existingWorkerInstances.getOrElse(Set.empty),
                                             SecondaryWorker -> secondaryWorkerInstances))

    Future.successful(())
  }
}
