#!/bin/bash
set -e

zone_id=$(./zone_id.sh)
container_name=kjarosz_sim_${zone_id}

if docker stop "${container_name}" >/dev/null 2>&1; then
  echo "Container stopped";
else
  echo "Container is not running";
  exit 1
fi

docker commit "${container_name}" kjarosh/ms-graph-simulator:saved
docker start "${container_name}"
