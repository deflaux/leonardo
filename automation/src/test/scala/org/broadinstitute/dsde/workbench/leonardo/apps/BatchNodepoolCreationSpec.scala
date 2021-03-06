package org.broadinstitute.dsde.workbench.leonardo
package apps

import java.nio.file.Paths

import cats.effect.IO
import cats.implicits._
import com.google.container.v1.{Cluster, NodePool}
import org.broadinstitute.dsde.workbench.DoneCheckable
import org.broadinstitute.dsde.workbench.auth.AuthToken
import org.broadinstitute.dsde.workbench.google2.GKEModels.{KubernetesClusterId, KubernetesClusterName}
import org.broadinstitute.dsde.workbench.google2.{streamFUntilDone, GKEService}
import org.broadinstitute.dsde.workbench.leonardo.LeonardoApiClient._
import org.broadinstitute.dsde.workbench.leonardo.http.{GetAppResponse, ListAppResponse, PersistentDiskRequest}
import org.http4s.headers.Authorization
import org.http4s.{AuthScheme, Credentials}
import org.scalatest.{DoNotDiscover, ParallelTestExecution}

import scala.jdk.CollectionConverters._
import scala.concurrent.duration._

@DoNotDiscover
class BatchNodepoolCreationSpec
    extends GPAllocFixtureSpec
    with LeonardoTestUtils
    with GPAllocUtils
    with ParallelTestExecution {

  implicit val ronToken: AuthToken = ronAuthToken
  implicit val auth: Authorization = Authorization(Credentials.Token(AuthScheme.Bearer, ronCreds.makeAuthToken().value))

  val gkeServiceResource = GKEService.resource(Paths.get(LeonardoConfig.GCS.pathToQAJson), blocker, semaphore)

  //the cluster and nodepools should be running
  val clusterDoneCheckable: DoneCheckable[Option[Cluster]] =
    x =>
      x.map(_.getStatus()) == Some(Cluster.Status.RUNNING) &&
        x.map(_.getNodePoolsList().asScala.toList.map(_.getStatus()).distinct) == Some(List(NodePool.Status.RUNNING))

  "batch nodepool creation should work" in { _ =>
    withNewProject { googleProject =>
      val test = LeonardoApiClient.client.use { implicit c =>
        for {
          clusterName <- IO.fromEither(KubernetesNameUtils.getUniqueName(KubernetesClusterName.apply))
          _ <- LeonardoApiClient.batchNodepoolCreate(googleProject,
                                                     defaultBatchNodepoolRequest.copy(clusterName = Some(clusterName)))
          getCluster = gkeServiceResource.use { gkeClient =>
            val id = KubernetesClusterId(googleProject, LeonardoConfig.Leonardo.location, clusterName)
            gkeClient.getCluster(id)
          }
          monitorCreationResult <- testTimer.sleep(30 seconds) >>
            streamFUntilDone(getCluster, 60, 10 seconds)(
              testTimer,
              clusterDoneCheckable
            ).compile.lastOrError

          _ = monitorCreationResult.map(_.getNodePoolsList().size()) shouldBe Some(
            defaultBatchNodepoolRequest.numNodepools.value + 1
          )
        } yield ()
      }

      test.unsafeRunSync()
    }
  }

  "app creation with batch nodepool creation should work" in { _ =>
    withNewProject { googleProject =>
      val test = LeonardoApiClient.client.use { implicit c =>
        val appName1 = randomAppName
        val appName2 = randomAppName

        val appDoneCheckable: DoneCheckable[GetAppResponse] =
          x => x.status == AppStatus.Running || x.status == AppStatus.Error

        val appDeletedDoneCheckable: DoneCheckable[List[ListAppResponse]] =
          x => x.map(_.status).distinct == List(AppStatus.Deleted)

        val app1DeletedDoneCheckable: DoneCheckable[List[ListAppResponse]] =
          x => x.filter(_.appName == appName1).map(_.status).distinct == List(AppStatus.Deleted)

        for {
          clusterName <- IO.fromEither(KubernetesNameUtils.getUniqueName(KubernetesClusterName.apply))
          _ <- LeonardoApiClient.batchNodepoolCreate(
            googleProject,
            defaultBatchNodepoolRequest.copy(clusterName = Some(clusterName), numNodepools = NumNodepools(1))
          )
          getCluster = gkeServiceResource.use { gkeClient =>
            val id = KubernetesClusterId(googleProject, LeonardoConfig.Leonardo.location, clusterName)
            gkeClient.getCluster(id)
          }

          monitorBatchCreationResult <- testTimer.sleep(30 seconds) >> streamFUntilDone(getCluster, 60, 10 seconds)(
            testTimer,
            clusterDoneCheckable
          ).compile.lastOrError

          //here we sleep, because the above verifies the google state and we need to wait until leo has polled and updated its internal state to proceed
          //it is a long time because there is a lot of stuff leo has to do besides GKE entity creation
          _ <- testTimer.sleep(5 minutes)

          _ = monitorBatchCreationResult.map(_.getNodePoolsList().size()) shouldBe Some(2)

          diskConfig1 = Some(PersistentDiskRequest(randomDiskName, None, None, Map.empty))

          _ <- loggerIO.info(s"BatchNodepoolCreationSpec: About to create app ${googleProject.value}/${appName1.value}")

          _ <- LeonardoApiClient.createApp(googleProject,
                                           appName1,
                                           createAppRequest = defaultCreateAppRequest.copy(diskConfig = diskConfig1))

          _ <- loggerIO.info(s"BatchNodepoolCreationSpec: About to get app ${googleProject.value}/${appName1.value}")

          getApp1 = LeonardoApiClient.getApp(googleProject, appName1)
          monitorApp1CreationResult <- testTimer.sleep(30 seconds) >> streamFUntilDone(getApp1, 120, 10 seconds)(
            testTimer,
            appDoneCheckable
          ).compile.lastOrError

          _ <- loggerIO.info(
            s"BatchNodepoolCreationSpec: app ${googleProject.value}/${appName1.value} monitor result: ${monitorApp1CreationResult}"
          )
          _ = monitorApp1CreationResult.status shouldBe AppStatus.Running

          clusterAfterApp1 <- getCluster
          _ = clusterAfterApp1.map(_.getNodePoolsList().size()) shouldBe Some(2)

          diskConfig2 = Some(PersistentDiskRequest(randomDiskName, None, None, Map.empty))

          _ <- loggerIO.info(s"BatchNodepoolCreationSpec: About to create app ${googleProject.value}/${appName2.value}")

          _ <- LeonardoApiClient.createApp(googleProject,
                                           appName2,
                                           createAppRequest = defaultCreateAppRequest.copy(diskConfig = diskConfig2))

          //creating a second app with 1 precreated nodepool should cause a second user nodepool to be created
          getApp2 = LeonardoApiClient.getApp(googleProject, appName2)
          monitorApp2CreationResult <- testTimer.sleep(30 seconds) >> streamFUntilDone(getApp2, 120, 10 seconds)(
            testTimer,
            appDoneCheckable
          ).compile.lastOrError

          _ <- loggerIO.info(
            s"BatchNodepoolCreationSpec: app ${googleProject.value}/${appName2.value} monitor result: ${monitorApp2CreationResult}"
          )
          _ = monitorApp2CreationResult.status shouldBe AppStatus.Running

          clusterAfterApp2 <- getCluster
          _ = clusterAfterApp2.map(_.getNodePoolsList().size()) shouldBe Some(3)

          // we can only delete 1 app at a time due to the google limitation that a cluster can only have 1 nodepool related operation ongoing at a time
          _ <- LeonardoApiClient.deleteApp(googleProject, appName1)

          listApps = LeonardoApiClient.listApps(googleProject, true)

          monitorApp1DeletionResult <- testTimer.sleep(30 seconds) >> streamFUntilDone(listApps, 120, 10 seconds)(
            testTimer,
            app1DeletedDoneCheckable
          ).compile.lastOrError

          _ <- loggerIO.info(
            s"BatchNodepoolCreationSpec: app ${googleProject.value}/${appName1.value} delete result: $monitorApp1DeletionResult"
          )

          _ = monitorApp1DeletionResult.map(_.status).toSet shouldBe Set(AppStatus.Deleted, AppStatus.Running)

          _ <- LeonardoApiClient.deleteApp(googleProject, appName2)
          monitorAppDeletionResult <- testTimer.sleep(30 seconds) >> streamFUntilDone(listApps, 120, 10 seconds)(
            testTimer,
            appDeletedDoneCheckable
          ).compile.lastOrError

          _ <- loggerIO.info(s"BatchNodepoolCreationSpec: all app delete result: $monitorAppDeletionResult")

        } yield ()
      }
      test.unsafeRunSync()
    }
  }

}
