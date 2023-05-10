#!/usr/bin/env bash

CURR_DIR=$(pwd)
MOUNT_DIR='/data'
JSON_FILE_ARGS=''
HAS_JSON=0
XML_FILE_ARGS=''
HAS_XML=0

DOCKER_USER=hpccsystems
DOCKER_REPO=solutions-lab
DOCKER_TAG=jx2ecl
IMAGE_NAME="${DOCKER_USER}/${DOCKER_REPO}:${DOCKER_TAG}"

DOCKER_EXEC='docker run --rm'

for f in "$@"
do
	if [[ "${f}" == -* || ! -f "${f}" ]]; then
		# Option; append to all args
		XML_FILE_ARGS="${XML_FILE_ARGS} ${f}"
		JSON_FILE_ARGS="${JSON_FILE_ARGS} ${f}"
	else
		BASE=$(basename "${f}")

		case "${BASE}" in
			*.xml)
                XML_FILE_ARGS="${XML_FILE_ARGS} ${MOUNT_DIR}/${f}"
                HAS_XML=1
                ;;
			*.json)
                JSON_FILE_ARGS="${JSON_FILE_ARGS} ${MOUNT_DIR}/${f}"
                HAS_JSON=1
                ;;
			*)
                echo "Unknown file type ${BASE}"
                exit 1
                ;;
		esac
	fi
done

# Parse JSON files
if [[ ${HAS_JSON} -eq 1 ]]; then
	echo
	echo ===== JSON =====
	echo
	${DOCKER_EXEC} -v ${CURR_DIR}:${MOUNT_DIR} ${IMAGE_NAME} json2ecl ${JSON_FILE_ARGS}
fi

# Parse XML files
if [[ ${HAS_XML} -eq 1 ]]; then
	echo
	echo ===== XML =====
	echo
	${DOCKER_EXEC} -v ${CURR_DIR}:${MOUNT_DIR} ${IMAGE_NAME} xml2ecl ${XML_FILE_ARGS}
fi
