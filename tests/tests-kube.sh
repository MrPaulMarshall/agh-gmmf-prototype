#!/bin/bash
set -eE -o functrace

failure() {
  local lineno=$1
  local msg=$2
  echo "Failed at $lineno: $msg"
  while true; do sleep 100; done
}
trap 'failure ${LINENO} "$BASH_COMMAND"' ERR

####################
# Global constants #
####################

# kubernetes
path_to_kubernetes_config="$HOME/.kube/student-k8s-cyf.yaml"
kubernetes_user_name=$(kubectl config view --minify | grep namespace: | cut -d':' -f2)

# constant paths
sql_py_scripts="sql-and-python"
results_root="results"

mkdir -p ${results_root}

# file names
test_config_path=${1:-'test-config.conf'}
echo "Config is:" "$test_config_path"
merged_csv_name="merged.csv"
graph_name="graph.json"
queries_name="queries.json"
plot_name="plot.png"
report_name="report.txt"
avg_report_name="avg-report.txt"

####################
# Global variables #
####################

# paths (yet to be determined) to navigate over results
path_for_test=""
path_for_graph=""
path_for_load=""
path_for_repetition=""

path_to_merged_csv=""
path_to_plot=""
path_to_report=""
path_to_average_report=""

path_to_graph=""
path_to_queries=""

# pods
COUNT_ZONES=0
ZONES=()
EXECUTOR=""

# number of repetition
TEST_TIME=0
REPETITIONS=0

####################
# Graphs and loads #
####################

# interzone levels
inter_zone_levels=()

# nodes per zone
spaces_per_zone=()

# data points - X coordinates
loads=()

#############
# Functions #
#############

my_printf() {
  printf "[tests-kube] %s\n" "$1"
}

parse_config() {
  source "${test_config_path}"
}

sync_pod_dir() {
  local pod=$1
  local source=$2
  local destination=$3

  devspace sync --pod="${pod}" \
    --namespace="${kubernetes_user_name}" \
    --container-path="${source}" \
    --local-path="${destination}" \
    --download-only \
    --no-watch \
    --verbose
}

# ZONES ON KUBERNETES

create_zones() {
  total_zones=$((COUNT_ZONES + 1))
  ./run-main.sh com.github.kjarosh.agh.pp.cli.KubernetesClient \
    -z ${total_zones} \
    -c ${path_to_kubernetes_config} \
    -n ${kubernetes_user_name}

  # local variables
  local incomings=1
  local pendings=1
  local creatings=1
  local runnings=0

  # loop
  while [[ ${incomings} -gt 0 || ${runnings} -ne ${total_zones} ]]; do
    # sleep
    sleep 5

    # check status of pods that will be run later
    pendings="$(kubectl get pod | grep -w Pending | wc -l)"
    creatings="$(kubectl get pod | grep -w ContainerCreating | wc -l)"
    incomings="$((pendings+creatings))"

    # check number of pods that are running now
    runnings="$(kubectl get pod | grep -w Running | wc -l)"
  done
}

load_zones() {
  ZONES=()
#  for ((i = 0; i < COUNT_ZONES; i++)); do
#    ZONES+=("$(kubectl get pod --field-selector=status.phase=Running -l "zone=zone${i}" -o name | sed 's/.*\///')")
#  done
#
#  EXECUTOR="$(kubectl get pod --field-selector=status.phase=Running -l "zone=zone${COUNT_ZONES}" -o name | sed 's/.*\///')"

  for ((i = 0; i < COUNT_ZONES; i++)); do
    newZone="$(kubectl get pod -l "zone=zone${i}" -n "$kubernetes_user_name" | grep -w Running | awk '{print $1;}')"
    my_printf "zone-${i} = ${newZone}"
    ZONES+=("${newZone}")
  done

  EXECUTOR="$(kubectl get pod -l "zone=zone${COUNT_ZONES}" -n "$kubernetes_user_name" | grep -w Running | awk '{print $1;}')"
  my_printf "executor = ${EXECUTOR}"
}

restart_zone() {
  my_printf "Restarting $1"
  kubectl -n "$kubernetes_user_name" rollout restart deployment "$1"
  kubectl -n "$kubernetes_user_name" rollout status deployment "$1"
  my_printf "Restarted $1"
}

restart_zones() {
  my_printf "Restarting zones"

  for ((i = 0; i < COUNT_ZONES; i++)); do
    restart_zone "zone${i}" &
  done
  wait

  load_zones

  my_printf "Zones restarted"
}

# NEW DIRECTORIES

mkdir_for_whole_test() {
  # create new directory
  timestamp=$(date +"D%Y-%m-%dT%T" | tr : -)
  path_for_test="${results_root}/test--${timestamp}"
  mkdir "${path_for_test}"

  # prepare paths
  path_to_merged_csv="${path_for_test}/${merged_csv_name}"
  path_to_plot="${path_for_test}/${plot_name}"

  # copy config
  cp "${test_config_path}" "${path_for_test}/test-config.txt"

  # create merged_csv file
  touch "${path_to_merged_csv}"
  echo 'interzone,spaces_per_zone,target,real,std' >"${path_to_merged_csv}"
}

mkdir_for_graph() {
  # remove file extension from name of the directory
  path_for_graph="${path_for_test}/graph--${1}-${2}"
  mkdir "${path_for_graph}"
}

mkdir_for_load() {
  path_for_load="${path_for_graph}/${1}"
  mkdir "${path_for_load}"

  path_to_average_report="${path_for_load}/${avg_report_name}"
  touch "${path_to_average_report}"
}

mkdir_for_repetition() {
  path_for_repetition="${path_for_load}/${1}"
  mkdir "${path_for_repetition}"

  path_to_report="${path_for_repetition}/${report_name}"
  touch "${path_to_report}"
}

# GENERATE GRAPHS AND QUERIES

generate_graph() {
  # $1 - interzone
  # $2 - spz

  path_to_graph="${path_for_graph}/${graph_name}"

  # graph-generation config
  pgc="${path_for_graph}/graph-config.json"

  # ASSUMPTION: 1 space pez zone 'generates' around 30 nodes per zone
  local interzone_param=${1}
  local spaces_param=${2}
  local providers_param=$((2 * spaces_param / 3))

  cat <<CONFIG > "${pgc}"
{
  "providers": ${providers_param},
  "spaces": ${spaces_param},
  "zones": 1,
  "providersPerSpace": "normal(1, 0.5)",
  "groupsPerGroup": "normal(2, 1)",
  "usersPerGroup": "normal(15, 4)",
  "treeDepth": "enormal(2.3, 1)",
  "differentGroupZoneProb": 0.${interzone_param},
  "differentUserZoneProb": 0.${interzone_param},
  "existingUserProb": 0.1,
  "existingGroupProb": 0.05
}
CONFIG

  echo "Generating graph..."
  ./run-main.sh com.github.kjarosh.agh.pp.cli.GraphGeneratorMain -c "${pgc}" -o "${path_to_graph}" -s ${COUNT_ZONES}
  echo "Graph generated"
}

generate_queries() {
  path_to_queries="${path_for_graph}/${queries_name}"

  max=${loads[0]}
  for n in "${loads[@]}" ; do
      ((n > max)) && max=$n
  done

  total_operations=$((TEST_TIME * max * 12 / 10))

  echo "Generating queries... n=${total_operations}"
  ./run-main.sh com.github.kjarosh.agh.pp.cli.OperationSequenceGeneratorMain -g ${path_to_graph} -n ${total_operations} -o ${path_to_queries}
  echo "Queries generated"
}

# INSTRUMENTATION

clear_instrumentation() {
  my_printf "Clearing instrumentation in $1"
  kubectl exec "$1" -- truncate -s 0 instrumentation.csv
}

clear_instrumentations() {
  for zone in ${ZONES[*]}; do
    clear_instrumentation "${zone}" &
  done
  wait

  my_printf "Instrumentation cleared"
}

get_instrumentation() {
  my_printf "Downloading artifacts for $1"
  kubectl cp "${ZONES[$1]}":instrumentation.csv "${path_for_repetition}/instrumentation-$1.csv"
}

get_all_instrumentations() {
  for ((i = 0; i < COUNT_ZONES; i++)); do
    get_instrumentation "${i}" &
  done
  wait

  my_printf "Artifacts downloaded"
}

# REDIS

clear_redis() {
  kubectl exec "$1" -- redis-cli FLUSHALL
}

clear_redises() {
  my_printf "Clearing redis"

  for ((i = 0; i < COUNT_ZONES; i++)); do
    clear_redis "${ZONES[i]}" &
  done
  wait
}

# POSTGRES

database() {
  psql "dbname='postgres'" -f "$1"
}

postgres_clear() {
  database ${sql_py_scripts}/truncate.sql
}

postgres_report() {
  database ${sql_py_scripts}/get_report.sql > "${path_to_report}" 2>&1
}

postgres_import() {
  ./run-main.sh com.github.kjarosh.agh.pp.cli.PostgresImportMain ${path_for_repetition}
}

calculate_avg_report() {
  # $1 = folder z wynikami testu
  echo "TODO"
  result=$(python3 sql-and-python/calculate_avg_report.py $1)
  echo "$result" >> "${path_to_merged_csv}"
}

# CONSTANT LOAD

load_graph() {
  clear_redises
  restart_zones
  kubectl cp "${path_to_graph}" "${EXECUTOR}:${graph_name}"
  kubectl cp "${path_to_queries}" "${EXECUTOR}:${queries_name}"

  kubectl exec "${EXECUTOR}" -- bash \
            -c "./run-main.sh com.github.kjarosh.agh.pp.cli.ConstantLoadClientMain -l -r 5 -g ${graph_name} -n 100 --no-load"


  # make sure there is a backup

  for ((i = 0; i < COUNT_ZONES; i++)); do
    (
      kubectl exec "${ZONES[i]}" -- redis-cli save
      kubectl exec "${ZONES[i]}" -- cp -p /var/lib/redis/dump.rdb /var/lib/redis/graph.rdb
    ) &
    my_printf "Redis state snapshoted for ${ZONES[i]}"
  done
  wait
}

constant_load() {
  # $1 - graph
  # $2 - queries
  # $3 - load
  # $4 - naive

  if [[ "${4}" = true ]] ; then
    kubectl exec "${EXECUTOR}" -- bash \
            -c "./run-main.sh com.github.kjarosh.agh.pp.cli.ConstantLoadClientMain -r 5 -g ${graph_name} -s ${queries_name} -n ${3} -d ${TEST_TIME} -t 10 --disable-indexation"
  else
    kubectl exec "${EXECUTOR}" -- bash \
            -c "./run-main.sh com.github.kjarosh.agh.pp.cli.ConstantLoadClientMain -r 5 -g ${graph_name} -s ${queries_name} -n ${3} -d ${TEST_TIME} -t 10"
  fi

  # restore previous redis state
  for ((i = 0; i < COUNT_ZONES; i++)); do
    kubectl exec "${ZONES[i]}" -- redis-cli shutdown
    kubectl exec "${ZONES[i]}" -- cp -p /var/lib/redis/graph.rdb /var/lib/redis/dump.rdb
    kubectl exec "${ZONES[i]}" -- redis-server /redis.conf
    my_printf "Redis state restored for ZONE ${ZONES[i]}"
  done
}

######################
# Single-test runner #
######################

run_test() {
  # $1 - graph
  # $2 - queries
  # $3 - load
  # $4 - naive (true/false)

  # clear csv and postgres
  clear_instrumentations
  postgres_clear
  my_printf "Postgres: CLEARED"

  # perform test
  constant_load "${1}" "${2}" "${3}" "${4}"

  # load results to postgres
  get_all_instrumentations
  postgres_import
  my_printf "Postgres: IMPORTED"

  # perform report and write final results to '${merged_csv_name}'
  postgres_report
  my_printf "Postgres: REPORT OBTAINED"

  restart_zones
}

####################
# SCRIPT EXECUTION #
####################
service postgresql start
runuser -l postgres -c 'cd / && createuser --superuser root && createdb root'
service postgresql restart >> logs.txt
psql -f ${sql_py_scripts}/set_postgres_passwd.sql >> logs.txt 
service postgresql restart >> logs.txt

# read config file
parse_config
echo "Config read"

# create pods and obtain references to them
# create_zones
load_zones
echo "Zones loaded"

## initialize new directory for test's results, including merged_csv file
mkdir_for_whole_test
echo "Directory structure created"

# for each interzone..
for interzone_arg in ${inter_zone_levels[*]}; do

  # if interzone is 'naive' default it to 10%
  if [[ ${interzone_arg} = "naive" ]] ; then
    interzone=10
  else
    interzone=${interzone_arg}
  fi

  # for each nodes-per-zone..
  for spz_arg in ${spaces_per_zone[*]}; do
    mkdir_for_graph "${interzone_arg}" "${spz_arg}"

    # if spaces-per-zone is 'naive' default it to 66 ( 2k nodes-per-zone )
    if [[ ${spz_arg} = "naive" ]] ; then
      spz=66
    else
      spz=${spz_arg}
    fi

    naive=false
    if [[ ${interzone_arg} = "naive" || ${spz_arg} = "naive" ]] ; then
      naive=true
    fi

    # generate graph and queries to perform
    generate_graph "${interzone}" "${spz}"
    generate_queries "${path_to_graph}"

    # load graph to kubernetes
    load_graph

    # for each load..
    for load in ${loads[*]}; do
      mkdir_for_load "${load}"

      # start new record in merged csv
      echo -n "${interzone_arg},${spz_arg},${load}," >> "${path_to_merged_csv}"

      # repeat test
      for i in $(seq 1 $REPETITIONS); do
        mkdir_for_repetition "${i}"
        run_test "${graph_name}" "${queries_name}" "${load}" ${naive}
      done

      # TODO calculate average report
      #...

      # TODO get value from average report to merged csv
      #grep 'Operations per second' "${path_to_average_report}" | cut -d':' -f6 | tr -d ' ' | head -n 1 >> "${path_to_merged_csv}"
      # echo "1" >> "${path_to_merged_csv}"

      calculate_avg_report "${path_for_load}" || true
    done

    # create plot from merged.csv
    python3 -W ignore "${sql_py_scripts}/plot.py" "${path_to_merged_csv}" "${path_to_plot}" || true

  done
done

tar -czvf results.tar.gz "${path_for_test}"
echo "Tar generated. Copy with:"
echo "kubectl -n ${kubernetes_user_name} cp $(kubectl get pods | grep gmm-tester | awk '{ print $1 }'):results.tar.gz results.tar.gz"

echo "Tests finished!"

### infinite loop waiting for manual termination
while :
do
    sleep 100
done
