#!/usr/bin/env bash

# This init script instantiates the tool (e.g. Jupyter) docker images on Google Compute Engine instances created by Leo.

set -e -x

#####################################################################################################
# Functions
#####################################################################################################

# Retry a command up to a specific number of times until it exits successfully,
# with exponential back off. For example:
#
#   $ retry 5 echo "Hello"
#     Hello
#
#   $ retry 5 false
#     Retry 1/5 exited 1, retrying in 2 seconds...
#     Retry 2/5 exited 1, retrying in 4 seconds...
#     Retry 3/5 exited 1, retrying in 8 seconds...
#     Retry 4/5 exited 1, retrying in 16 seconds...
#     Retry 5/5 exited 1, no more retries left.
function retry {
  local retries=$1
  shift

  for ((i = 1; i <= $retries; i++)); do
    # run with an 'or' so set -e doesn't abort the bash script on errors
    exit=0
    "$@" || exit=$?
    if [ $exit -eq 0 ]; then
      return 0
    fi
    wait=$((2 ** $i))
    if [ $i -eq $retries ]; then
      log "Retry $i/$retries exited $exit, no more retries left."
      break
    fi
    log "Retry $i/$retries exited $exit, retrying in $wait seconds..."
    sleep $wait
  done
  return 1
}

function log() {
  echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')]: $@"
}

display_time() {
  local T=$1
  local D=$((T/60/60/24))
  local H=$((T/60/60%24))
  local M=$((T/60%60))
  local S=$((T%60))
  (( $D > 0 )) && printf '%d days ' $D
  (( $H > 0 )) && printf '%d hours ' $H
  (( $M > 0 )) && printf '%d minutes ' $M
  (( $D > 0 || $H > 0 || $M > 0 )) && printf 'and '
  printf '%d seconds\n' $S
}

#####################################################################################################
# Main starts here. It is composed of three sections:
#   1. Set up that is NOT specific to RUNTIME_OPERATION
#   2. Operations we want to perform only when we are 'creating' a VM
#   3. Operations we want to perform only when we are 'restarting' a VM that was previously created
#####################################################################################################

# Array for instrumentation
# UPDATE THIS IF YOU ADD MORE STEPS:
# currently the steps are:
# START init,
# .. after env setup
# .. after copying files from google and into docker
# .. after docker compose
# .. after welder start
# .. after hail and spark
# .. after nbextension install
# .. after server extension install
# .. after combined extension install
# .. after user script
# .. after lab extension install
# .. after jupyter notebook start
# END

# Note the start time so we can display the elapsed time at the end
START_TIME=$(date +%s)

#####################################################################################################
# Set up that is NOT specific to RUNTIME_OPERATION
#####################################################################################################
RUNTIME_OPERATION=$(runtimeOperation)
JUPYTER_HOME=/etc/jupyter

log "Running GCE VM init script in $RUNTIME_OPERATION mode..."

export CLUSTER_NAME=$(clusterName)
export RUNTIME_NAME=$(clusterName)
export GOOGLE_PROJECT=$(googleProject)
export STAGING_BUCKET=$(stagingBucketName)
export OWNER_EMAIL=$(loginHint)
export JUPYTER_SERVER_NAME=$(jupyterServerName)
export JUPYTER_DOCKER_IMAGE=$(jupyterDockerImage)
export JUPYTER_START_USER_SCRIPT_URI=$(jupyterStartUserScriptUri)
# Include a timestamp suffix to differentiate different startup logs across restarts.
export JUPYTER_START_USER_SCRIPT_OUTPUT_URI=$(jupyterStartUserScriptOutputUri)
export NOTEBOOKS_DIR=$(notebooksDir)
export WELDER_SERVER_NAME=$(welderServerName)
export WELDER_DOCKER_IMAGE=$(welderDockerImage)
export WELDER_ENABLED=$(welderEnabled)
export IS_GCE_FORMATTED=$(isGceFormatted)

#####################################################################################################
# Set up that IS specific to RUNTIME_OPERATION:
#
# We perform some of the operations based on whether we are 'creating' a GCE VM or 'restarting'
# a VM that was previously created and stopped.
#####################################################################################################

if [[ "$RUNTIME_OPERATION" == 'creating' ]]; then
    JUPYTER_SCRIPTS=${JUPYTER_HOME}/scripts
    JUPYTER_USER_HOME=/home/jupyter-user
    KERNELSPEC_HOME=/usr/local/share/jupyter/kernels

    # The following values are populated by Leo when a cluster is created.
    export RSTUDIO_SERVER_NAME=$(rstudioServerName)
    export PROXY_SERVER_NAME=$(proxyServerName)
    export RSTUDIO_DOCKER_IMAGE=$(rstudioDockerImage)
    export PROXY_DOCKER_IMAGE=$(proxyDockerImage)
    export MEM_LIMIT=$(memLimit)
    export WELDER_MEM_LIMIT=$(welderMemLimit)
    export PROXY_SERVER_HOST_NAME=$(proxyServerHostName)

    SERVER_CRT=$(proxyServerCrt)
    SERVER_KEY=$(proxyServerKey)
    ROOT_CA=$(rootCaPem)
    JUPYTER_DOCKER_COMPOSE_GCE=$(jupyterDockerComposeGce)
    RSTUDIO_DOCKER_COMPOSE=$(rstudioDockerCompose)
    PROXY_DOCKER_COMPOSE=$(proxyDockerCompose)
    WELDER_DOCKER_COMPOSE=$(welderDockerCompose)
    PROXY_SITE_CONF=$(proxySiteConf)
    JUPYTER_SERVER_EXTENSIONS=$(jupyterServerExtensions)
    JUPYTER_NB_EXTENSIONS=$(jupyterNbExtensions)
    JUPYTER_COMBINED_EXTENSIONS=$(jupyterCombinedExtensions)
    JUPYTER_LAB_EXTENSIONS=$(jupyterLabExtensions)
    JUPYTER_USER_SCRIPT_URI=$(jupyterUserScriptUri)
    JUPYTER_USER_SCRIPT_OUTPUT_URI=$(jupyterUserScriptOutputUri)
    JUPYTER_NOTEBOOK_CONFIG_URI=$(jupyterNotebookConfigUri)
    JUPYTER_NOTEBOOK_FRONTEND_CONFIG_URI=$(jupyterNotebookFrontendConfigUri)
    CUSTOM_ENV_VARS_CONFIG_URI=$(customEnvVarsConfigUri)
    RSTUDIO_LICENSE_FILE=$(rstudioLicenseFile)

    log 'Copying secrets from GCS...'

    mkdir -p /work
    mkdir -p /certs
    # Format and mount persisent disk
    export DISK_DEVICE_ID=$(lsblk -o name,serial | grep 'user-disk' | awk '{print $1}')
    # Only format disk is it hasn't already been formatted
    if [ "$IS_GCE_FORMATTED" == "false" ] ; then
      mkfs.ext4 -m 0 -E lazy_itable_init=0,lazy_journal_init=0,discard /dev/${DISK_DEVICE_ID}
    fi
    mount -o discard,defaults /dev/${DISK_DEVICE_ID} /work
    # Directory to store user installed packages so they persist
    mkdir -p /work/packages
    chmod a+rwx /work/packages
    # Ensure peristent disk re-mounts if runtime stops and restarts
    cp /etc/fstab /etc/fstab.backup
    echo UUID=`blkid -s UUID -o value /dev/${DISK_DEVICE_ID}` /work ext4 discard,defaults,nofail 0 2 | tee -a /etc/fstab
    chmod a+rwx /work

    # Add the certificates from the bucket to the VM. They are used by the docker-compose file
    gsutil cp ${SERVER_CRT} /certs
    gsutil cp ${SERVER_KEY} /certs
    gsutil cp ${ROOT_CA} /certs
    gsutil cp ${PROXY_SITE_CONF} /etc
    gsutil cp ${JUPYTER_DOCKER_COMPOSE_GCE} /etc
    gsutil cp ${RSTUDIO_DOCKER_COMPOSE} /etc
    gsutil cp ${PROXY_DOCKER_COMPOSE} /etc
    gsutil cp ${WELDER_DOCKER_COMPOSE} /etc

    # Not all images have the directory used for Stackdriver configs. If so, create it
    mkdir -p /etc/google-fluentd/config.d

    # Add stack driver configuration for welder
    tee /etc/google-fluentd/config.d/welder.conf << END
<source>
 @type tail
 format json
 path /work/welder.log
 pos_file /var/tmp/fluentd.welder.pos
 read_from_head true
 tag welder
</source>
END

    # Add stack driver configuration for jupyter
    tee /etc/google-fluentd/config.d/jupyter.conf << END
<source>
 @type tail
 format none
 path /work/jupyter.log
 pos_file /var/tmp/fluentd.jupyter.pos
 read_from_head true
 tag jupyter
</source>
END

    # Add stack driver configuration for user startup and shutdown scripts
    tee /etc/google-fluentd/config.d/daemon.conf << END
<source>
 @type tail
 format none
 path /var/log/daemon.log
 pos_file /var/tmp/fluentd.google.user.daemon.pos
 read_from_head true
 tag daemon
</source>
END

    # restarting instead of `service google-fluentd-reload` because of bug:
    # https://github.com/GoogleCloudPlatform/google-fluentd/issues/232
    service google-fluentd restart

    echo "" > /etc/google_application_credentials.env

    # Install env var config
    if [ ! -z "$CUSTOM_ENV_VARS_CONFIG_URI" ] ; then
      log 'Copy custom env vars config...'
      gsutil cp ${CUSTOM_ENV_VARS_CONFIG_URI} /etc
    fi

    # Install RStudio license file, if specified
    if [ ! -z "$RSTUDIO_DOCKER_IMAGE" ] ; then
      # TODO: remove the gsutil stat command when https://github.com/broadinstitute/firecloud-develop/pull/2105
      # is merged because then we'll expect the license file to always be present.
      STAT_EXIT_CODE=0
      gsutil -q stat ${RSTUDIO_LICENSE_FILE} || STAT_EXIT_CODE=$?
      if [ $STAT_EXIT_CODE -eq 0 ] ; then
        echo "Using RStudio license file $RSTUDIO_LICENSE_FILE"
        gsutil cp ${RSTUDIO_LICENSE_FILE} /etc/rstudio-license-file.lic
      else
        echo "" > /etc/rstudio-license-file.lic
      fi
    fi

    # If any image is hosted in a GCR registry (detected by regex) then
    # authorize docker to interact with gcr.io.
    if grep -qF "gcr.io" <<< "${JUPYTER_DOCKER_IMAGE}${RSTUDIO_DOCKER_IMAGE}${PROXY_DOCKER_IMAGE}${WELDER_DOCKER_IMAGE}" ; then
      log 'Authorizing GCR...'
      gcloud --quiet auth configure-docker
    fi

    log 'Starting up the Jupydocker...'

    # Run docker-compose for each specified compose file.
    # Note the `docker-compose pull` is retried to avoid intermittent network errors, but
    # `docker-compose up` is not retried since if that fails, something is probably broken
    # and wouldn't be remedied by retrying
    COMPOSE_FILES=(-f /etc/`basename ${PROXY_DOCKER_COMPOSE}`)
    cat /etc/`basename ${PROXY_DOCKER_COMPOSE}`
    if [ ! -z "$JUPYTER_DOCKER_IMAGE" ] ; then
      COMPOSE_FILES+=(-f /etc/`basename ${JUPYTER_DOCKER_COMPOSE_GCE}`)
      cat /etc/`basename ${JUPYTER_DOCKER_COMPOSE_GCE}`
    fi
    if [ ! -z "$RSTUDIO_DOCKER_IMAGE" ] ; then
      COMPOSE_FILES+=(-f /etc/`basename ${RSTUDIO_DOCKER_COMPOSE}`)
      cat /etc/`basename ${RSTUDIO_DOCKER_COMPOSE}`
    fi
    if [ ! -z "$WELDER_DOCKER_IMAGE" ] && [ "$WELDER_ENABLED" == "true" ] ; then
      COMPOSE_FILES+=(-f /etc/`basename ${WELDER_DOCKER_COMPOSE}`)
      cat /etc/`basename ${WELDER_DOCKER_COMPOSE}`
    fi

    docker-compose "${COMPOSE_FILES[@]}" config
    retry 5 docker-compose "${COMPOSE_FILES[@]}" pull
    docker-compose "${COMPOSE_FILES[@]}" up -d

    # If Welder is installed, start the service.
    # See https://broadworkbench.atlassian.net/browse/IA-1026
    if [ ! -z "$WELDER_DOCKER_IMAGE" ] && [ "$WELDER_ENABLED" == "true" ] ; then
      log 'Starting Welder (file synchronization service)...'
      retry 3 docker exec -d ${WELDER_SERVER_NAME} /opt/docker/bin/entrypoint.sh
    fi

    # Jupyter-specific setup, only do if Jupyter is installed
    if [ ! -z "$JUPYTER_DOCKER_IMAGE" ] ; then
      log 'Installing Jupydocker kernelspecs...'

      # Used to pip install packacges
      # TODO: update this if we upgrade python version
      ROOT_USER_PIP_DIR=/usr/local/lib/python3.7/dist-packages
      JUPYTER_USER_PIP_DIR=/home/jupyter-user/.local/lib/python3.7/site-packages

      # Install kernelspecs inside the Jupyter container
      # TODO This is baked into terra-jupyter-base as of version 0.0.6. Keeping it here for now to support prior image versions.
      retry 3 docker exec -u root ${JUPYTER_SERVER_NAME} ${JUPYTER_SCRIPTS}/kernel/kernelspec.sh ${JUPYTER_SCRIPTS}/kernel ${KERNELSPEC_HOME}

      # Install jupyter_notebook_config.py
      # TODO This is baked into terra-jupyter-base as of version 0.0.6. Keeping it here for now to support prior image versions.
      if [ ! -z "$JUPYTER_NOTEBOOK_CONFIG_URI" ] ; then
        log 'Copy Jupyter notebook config...'
        gsutil cp ${JUPYTER_NOTEBOOK_CONFIG_URI} /etc
        JUPYTER_NOTEBOOK_CONFIG=`basename ${JUPYTER_NOTEBOOK_CONFIG_URI}`
        docker cp /etc/${JUPYTER_NOTEBOOK_CONFIG} ${JUPYTER_SERVER_NAME}:${JUPYTER_HOME}/
      fi

      # Install notebook.json
      if [ ! -z "$JUPYTER_NOTEBOOK_FRONTEND_CONFIG_URI" ] ; then
        log 'Copy Jupyter frontend notebook config...'
        gsutil cp ${JUPYTER_NOTEBOOK_FRONTEND_CONFIG_URI} /etc
        JUPYTER_NOTEBOOK_FRONTEND_CONFIG=`basename ${JUPYTER_NOTEBOOK_FRONTEND_CONFIG_URI}`
        docker cp /etc/${JUPYTER_NOTEBOOK_FRONTEND_CONFIG} ${JUPYTER_SERVER_NAME}:${JUPYTER_HOME}/nbconfig/
      fi

      # Install NbExtensions
      if [ ! -z "$JUPYTER_NB_EXTENSIONS" ] ; then
        for ext in ${JUPYTER_NB_EXTENSIONS}
        do
          log 'Installing Jupyter NB extension [$ext]...'
          if [[ $ext == 'gs://'* ]]; then
            gsutil cp $ext /etc
            JUPYTER_EXTENSION_ARCHIVE=`basename $ext`
            docker cp /etc/${JUPYTER_EXTENSION_ARCHIVE} ${JUPYTER_SERVER_NAME}:${JUPYTER_HOME}/${JUPYTER_EXTENSION_ARCHIVE}
            retry 3 docker exec -u root -e PIP_TARGET=${ROOT_USER_PIP_DIR} ${JUPYTER_SERVER_NAME} ${JUPYTER_SCRIPTS}/extension/jupyter_install_notebook_extension.sh ${JUPYTER_HOME}/${JUPYTER_EXTENSION_ARCHIVE}
          elif [[ $ext == 'http://'* || $ext == 'https://'* ]]; then
            JUPYTER_EXTENSION_FILE=`basename $ext`
            curl $ext -o /etc/${JUPYTER_EXTENSION_FILE}
            docker cp /etc/${JUPYTER_EXTENSION_FILE} ${JUPYTER_SERVER_NAME}:${JUPYTER_HOME}/${JUPYTER_EXTENSION_FILE}
            retry 3 docker exec -u root -e PIP_TARGET=${ROOT_USER_PIP_DIR} ${JUPYTER_SERVER_NAME} ${JUPYTER_SCRIPTS}/extension/jupyter_install_notebook_extension.sh ${JUPYTER_HOME}/${JUPYTER_EXTENSION_FILE}
          else
            retry 3 docker exec -u root -e PIP_TARGET=${ROOT_USER_PIP_DIR} ${JUPYTER_SERVER_NAME} ${JUPYTER_SCRIPTS}/extension/jupyter_pip_install_notebook_extension.sh $ext
          fi
        done
      fi

      # Install serverExtensions
      if [ ! -z "$JUPYTER_SERVER_EXTENSIONS" ] ; then
        for ext in ${JUPYTER_SERVER_EXTENSIONS}
        do
          log 'Installing Jupyter server extension [$ext]...'
          if [[ $ext == 'gs://'* ]]; then
            gsutil cp $ext /etc
            JUPYTER_EXTENSION_ARCHIVE=`basename $ext`
            docker cp /etc/${JUPYTER_EXTENSION_ARCHIVE} ${JUPYTER_SERVER_NAME}:${JUPYTER_HOME}/${JUPYTER_EXTENSION_ARCHIVE}
            retry 3 docker exec -u root -e PIP_TARGET=${ROOT_USER_PIP_DIR} ${JUPYTER_SERVER_NAME} ${JUPYTER_SCRIPTS}/extension/jupyter_install_server_extension.sh ${JUPYTER_HOME}/${JUPYTER_EXTENSION_ARCHIVE}
          else
            retry 3 docker exec -u root -e PIP_TARGET=${ROOT_USER_PIP_DIR} ${JUPYTER_SERVER_NAME} ${JUPYTER_SCRIPTS}/extension/jupyter_pip_install_server_extension.sh $ext
          fi
        done
      fi

      # Install combined extensions
      if [ ! -z "$JUPYTER_COMBINED_EXTENSIONS"  ] ; then
        for ext in ${JUPYTER_COMBINED_EXTENSIONS}
        do
          log 'Installing Jupyter combined extension [$ext]...'
          log $ext
          if [[ $ext == 'gs://'* ]]; then
            gsutil cp $ext /etc
            JUPYTER_EXTENSION_ARCHIVE=`basename $ext`
            docker cp /etc/${JUPYTER_EXTENSION_ARCHIVE} ${JUPYTER_SERVER_NAME}:${JUPYTER_HOME}/${JUPYTER_EXTENSION_ARCHIVE}
            retry 3 docker exec -u root -e PIP_TARGET=${ROOT_USER_PIP_DIR} ${JUPYTER_SERVER_NAME} ${JUPYTER_SCRIPTS}/extension/jupyter_install_combined_extension.sh ${JUPYTER_EXTENSION_ARCHIVE}
          else
            retry 3 docker exec -u root -e PIP_TARGET=${ROOT_USER_PIP_DIR} ${JUPYTER_SERVER_NAME} ${JUPYTER_SCRIPTS}/extension/jupyter_pip_install_combined_extension.sh $ext
          fi
        done
      fi

      # If a Jupyter user script was specified, copy it into the jupyter docker container and execute it.
      if [ ! -z "$JUPYTER_USER_SCRIPT_URI" ] ; then
        log 'Running Jupyter user script [$JUPYTER_USER_SCRIPT_URI]...'
        JUPYTER_USER_SCRIPT=`basename ${JUPYTER_USER_SCRIPT_URI}`
        if [[ "$JUPYTER_USER_SCRIPT_URI" == 'gs://'* ]]; then
          gsutil cp ${JUPYTER_USER_SCRIPT_URI} /etc
        else
          curl $JUPYTER_USER_SCRIPT_URI -o /etc/${JUPYTER_USER_SCRIPT}
        fi
        docker cp /etc/${JUPYTER_USER_SCRIPT} ${JUPYTER_SERVER_NAME}:${JUPYTER_HOME}/${JUPYTER_USER_SCRIPT}
        retry 3 docker exec -u root ${JUPYTER_SERVER_NAME} chmod +x ${JUPYTER_HOME}/${JUPYTER_USER_SCRIPT}
        # Execute the user script as privileged to allow for deeper customization of VM behavior, e.g. installing
        # network egress throttling. As docker is not a security layer, it is assumed that a determined attacker
        # can gain full access to the VM already, so using this flag is not a significant escalation.
        EXIT_CODE=0
        docker exec --privileged -u root -e PIP_TARGET=${ROOT_USER_PIP_DIR} ${JUPYTER_SERVER_NAME} ${JUPYTER_HOME}/${JUPYTER_USER_SCRIPT} &> us_output.txt || EXIT_CODE=$?

        if [ $EXIT_CODE -ne 0 ]; then
            log "User script failed with exit code $EXIT_CODE. Output is saved to $JUPYTER_USER_SCRIPT_OUTPUT_URI."
            retry 3 gsutil -h "x-goog-meta-passed":"false" cp us_output.txt ${JUPYTER_USER_SCRIPT_OUTPUT_URI}
            exit $EXIT_CODE
        else
            retry 3 gsutil -h "x-goog-meta-passed":"true" cp us_output.txt ${JUPYTER_USER_SCRIPT_OUTPUT_URI}
        fi
      fi

      # If a Jupyter start user script was specified, copy it into the jupyter docker container for consumption during startups.
      if [ ! -z "$JUPYTER_START_USER_SCRIPT_URI" ] ; then
        log 'Copying Jupyter start user script [$JUPYTER_START_USER_SCRIPT_URI]...'
        JUPYTER_START_USER_SCRIPT=`basename ${JUPYTER_START_USER_SCRIPT_URI}`
        if [[ "$JUPYTER_START_USER_SCRIPT_URI" == 'gs://'* ]]; then
          gsutil cp ${JUPYTER_START_USER_SCRIPT_URI} /etc
        else
          curl $JUPYTER_START_USER_SCRIPT_URI -o /etc/${JUPYTER_START_USER_SCRIPT}
        fi
        docker cp /etc/${JUPYTER_START_USER_SCRIPT} ${JUPYTER_SERVER_NAME}:${JUPYTER_HOME}/${JUPYTER_START_USER_SCRIPT}
        retry 3 docker exec -u root ${JUPYTER_SERVER_NAME} chmod +x ${JUPYTER_HOME}/${JUPYTER_START_USER_SCRIPT}

        # Keep in sync with startup.sh
        log 'Executing Jupyter user start script [$JUPYTER_START_USER_SCRIPT]...'
        EXIT_CODE=0
        docker exec --privileged -u root -e PIP_TARGET=${ROOT_USER_PIP_DIR} ${JUPYTER_SERVER_NAME} ${JUPYTER_HOME}/${JUPYTER_START_USER_SCRIPT} &> start_output.txt || EXIT_CODE=$?
        if [ $EXIT_CODE -ne 0 ]; then
          echo "User start script failed with exit code ${EXIT_CODE}. Output is saved to ${JUPYTER_START_USER_SCRIPT_OUTPUT_URI}"
          retry 3 gsutil -h "x-goog-meta-passed":"false" cp start_output.txt ${JUPYTER_START_USER_SCRIPT_OUTPUT_URI}
          exit $EXIT_CODE
        else
          retry 3 gsutil -h "x-goog-meta-passed":"true" cp start_output.txt ${JUPYTER_START_USER_SCRIPT_OUTPUT_URI}
        fi
      fi

      # Install lab extensions
      # Note: lab extensions need to installed as jupyter user, not root
      if [ ! -z "$JUPYTER_LAB_EXTENSIONS" ] ; then
        for ext in ${JUPYTER_LAB_EXTENSIONS}
        do
          log 'Installing JupyterLab extension [$ext]...'
          pwd
          if [[ $ext == 'gs://'* ]]; then
            gsutil cp -r $ext /etc
            JUPYTER_EXTENSION_ARCHIVE=`basename $ext`
            docker cp /etc/${JUPYTER_EXTENSION_ARCHIVE} ${JUPYTER_SERVER_NAME}:${JUPYTER_HOME}/${JUPYTER_EXTENSION_ARCHIVE}
            retry 3 docker exec -e PIP_TARGET=${JUPYTER_USER_PIP_DIR} ${JUPYTER_SERVER_NAME} ${JUPYTER_SCRIPTS}/extension/jupyter_install_lab_extension.sh ${JUPYTER_HOME}/${JUPYTER_EXTENSION_ARCHIVE}
          elif [[ $ext == 'http://'* || $ext == 'https://'* ]]; then
            JUPYTER_EXTENSION_FILE=`basename $ext`
            curl $ext -o /etc/${JUPYTER_EXTENSION_FILE}
            docker cp /etc/${JUPYTER_EXTENSION_FILE} ${JUPYTER_SERVER_NAME}:${JUPYTER_HOME}/${JUPYTER_EXTENSION_FILE}
            retry 3 docker exec -e PIP_TARGET=${JUPYTER_USER_PIP_DIR} ${JUPYTER_SERVER_NAME} ${JUPYTER_SCRIPTS}/extension/jupyter_install_lab_extension.sh ${JUPYTER_HOME}/${JUPYTER_EXTENSION_FILE}
          else
            retry 3 docker exec -e PIP_TARGET=${JUPYTER_USER_PIP_DIR} ${JUPYTER_SERVER_NAME} ${JUPYTER_SCRIPTS}/extension/jupyter_install_lab_extension.sh $ext
          fi
        done
      fi

      # See IA-1901: Jupyter UI stalls indefinitely on initial R kernel connection after cluster create/resume
      # The intent of this is to "warm up" R at VM creation time to hopefully prevent issues when the Jupyter
      # kernel tries to connect to it.
      docker exec $JUPYTER_SERVER_NAME /bin/bash -c "R -e '1+1'" || true

      log 'Starting Jupyter Notebook...'
      retry 3 docker exec -d ${JUPYTER_SERVER_NAME} ${JUPYTER_SCRIPTS}/run-jupyter.sh ${NOTEBOOKS_DIR}
    fi

    # Remove any unneeded cached images to save disk space.
    # Do this asynchronously so it doesn't hold up cluster creation
    log 'Pruning docker images...'
    docker image prune -a -f &

# TODO (RT): I'm pretty sure this block is never used because we have a dedicated startup.sh script
# used for starting runtimes. We could confirm this and remove this block.
elif [[ "$RUNTIME_OPERATION" == 'restarting' ]]; then
  export UPDATE_WELDER=$(updateWelder)
  export DISABLE_DELOCALIZATION=$(disableDelocalization)

  # Sometimes we want to update Welder without having to delete and recreate a cluster
  if [ "$UPDATE_WELDER" == "true" ] ; then
      gcloud auth configure-docker
      docker-compose -f /etc/welder-docker-compose.yaml stop
      docker-compose -f /etc/welder-docker-compose.yaml rm -f
      retry 5 docker-compose -f /etc/welder-docker-compose.yaml pull
      docker-compose -f /etc/welder-docker-compose.yaml up -d
  fi

  # If a Jupyter start user script was specified, execute it now. It should already be in the docker container
  # via initialization at VM creation time. We do not want to recopy it from GCS on every cluster restart.
  if [ ! -z "$JUPYTER_START_USER_SCRIPT_URI" ] ; then
    JUPYTER_START_USER_SCRIPT=`basename ${JUPYTER_START_USER_SCRIPT_URI}`
    log 'Executing Jupyter user start script [$JUPYTER_START_USER_SCRIPT]...'
    EXIT_CODE=0
    docker exec --privileged -u root -e PIP_USER=false ${JUPYTER_SERVER_NAME} ${JUPYTER_HOME}/${JUPYTER_START_USER_SCRIPT} &> start_output.txt || EXIT_CODE=$?
    if [ $EXIT_CODE -ne 0 ]; then
      echo "User start script failed with exit code ${EXIT_CODE}. Output is saved to ${JUPYTER_START_USER_SCRIPT_OUTPUT_URI}"
      retry 3 gsutil -h "x-goog-meta-passed":"false" cp start_output.txt ${JUPYTER_START_USER_SCRIPT_OUTPUT_URI}
      exit $EXIT_CODE
    else
      retry 3 gsutil -h "x-goog-meta-passed":"true" cp start_output.txt ${JUPYTER_START_USER_SCRIPT_OUTPUT_URI}
    fi
  fi

  # By default GCE restarts containers on exit so we're not explicitly starting them below

  # Configuring Jupyter
  if [ ! -z "$JUPYTER_DOCKER_IMAGE" ] ; then
      # See IA-1901: Jupyter UI stalls indefinitely on initial R kernel connection after cluster create/resume
      # The intent of this is to "warm up" R at VM creation time to hopefully prevent issues when the Jupyter
      # kernel tries to connect to it.
      docker exec $JUPYTER_SERVER_NAME /bin/bash -c "R -e '1+1'" || true

      echo "Starting Jupyter on cluster $GOOGLE_PROJECT / $CLUSTER_NAME..."
      docker exec -d $JUPYTER_SERVER_NAME /bin/bash -c "export WELDER_ENABLED=$WELDER_ENABLED && export NOTEBOOKS_DIR=$NOTEBOOKS_DIR && (/etc/jupyter/scripts/run-jupyter.sh $NOTEBOOKS_DIR || /usr/local/bin/jupyter notebook)"

      # TODO: Do we still need this for GCE?
      if [ "$WELDER_ENABLED" == "true" ] ; then
          # fix for https://broadworkbench.atlassian.net/browse/IA-1453
          # TODO: remove this when we stop supporting the legacy docker image
          docker exec -u root jupyter-server sed -i -e 's/export WORKSPACE_NAME=.*/export WORKSPACE_NAME="$(basename "$(dirname "$(pwd)")")"/' /etc/jupyter/scripts/kernel/kernel_bootstrap.sh
      fi
  fi

  # Configuring Welder, if enabled
  if [ "$WELDER_ENABLED" == "true" ] ; then
      echo "Starting Welder on cluster $GOOGLE_PROJECT / $CLUSTER_NAME..."
      docker exec -d $WELDER_SERVER_NAME /bin/bash -c "export STAGING_BUCKET=$STAGING_BUCKET && /opt/docker/bin/entrypoint.sh"
  fi
else
  log "Invalid RUNTIME_OPERATION: $RUNTIME_OPERATION. Expected it to be either 'creating' or 'restarting'."
  exit 1
fi

log 'All done!'

END_TIME=$(date +%s)
ELAPSED_TIME=$(($END_TIME - $START_TIME))
log "gce-init.sh took "
display_time $ELAPSED_TIME
