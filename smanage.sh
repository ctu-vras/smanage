#!/bin/bash 
#
# smanage.sh
# Slurm Manage, for submitting and reporting on job arrays run on slurm
#
# MIT License
# Copyright (c) 2018 Erik Surface
#

#### SMANAGE_EXT_SOURCE ####
# define SMANAGE_EXT_SOURCE to add a script to parse the .err or .out files
# in the script, define a function called '_ext_handle_completed' that will be passed
# a bash list of jobs. See _ext_handle_example.
if [[ -n $SMANAGE_EXT_SOURCE ]]; then
source $SMANAGE_EXT_SOURCE
fi

#### USAGE ####

usage() {	
if [ -z $1 ]; then
    usage_general
elif [[ $1 = "config" ]]; then
    usage_config_mode
elif [[ $1 = "report" ]]; then
    usage_report_mode
elif [[ $1 = "submit" ]]; then
    usage_submit_mode
else
    usage_general
fi
}

usage_general(){
echo 'usage: smanage [FLAGS] <MODE> [SACCT_ARGS]'
echo "
FLAGS:
-a|--array:  Signal that jobs to report on are from sbatch --array
-h|--help:   Show help messages. For a specific mode try, --help <MODE>
-d|--debug:  Run smanage in debug mode (performs a dry-run of slurm commands)
-v|--verbose: Print more information at each step

MODE: 
report (default): output information on jobs reported by an sacct call
submit: provided an sbatch script to to submit an array of jobs
config: Convenience function to create or append to a config file 

SACCT_ARGS: 
Add sacct arguments after smanage args
They can also be passed by setting SACCT_ARGS as an environment variable 

SMANAGE_EXT_SOURCE:
Define the env variable SMANAGE_EXT_SOURCE to add a script to parse the .err or .out files
In the script, define a function called '_ext_handle_completed' that will be passed a bash list of jobs. See _ext_handle_example.

"
}

usage_config_mode() {
echo 'usage: smanage config 
  [--append <--config <CONFIG> [--jobids=<job_id>[,job_id,...]] ]
  [--create <--jobname <job_name>> <--jobdir <job_dir>> [--jobids=<job_id>[,job_id,...]] ]
  [--reset <--config <CONFIG>]
Create, reset or append job ids to a config file
'
}

usage_report_mode() {
echo 'usage: smanage report [--config <CONFIG>] [SACCT_ARGS]
Output the report for jobs defined by CONFIG and SACCT_ARGS
'
}

usage_submit_mode() {
echo 'usage: smanage --submit [--config <CONFIG>]
usage: smanage --submit <<--batch_name <batch_name>> <--batch_dir <batch_dir>> 
                          <--batch_prefix> <batch_prefix>>>
                         [--max_id <#>] [--reserve <#>] [--array <#-#>]
                         [--reservation <reservation>] [--partition <partition>]
'
usage_config_file
}

usage_config_file() {
echo '
Config File Options:

#SLURM MGR SUMBIT OPTIONS
BATCH_DIR=[directory where the batch of jobs is stored]
BATCH_PREFIX=[the prefix name for the batch set]
BATCH_NAME=[optional name of the batch as it will appear in an sacct query]
BATCH_SCRIPT=[sbatch script to run]

RESERVE=[size of the reservation aka number of jobs allows at a time]
MAX_ID=[max job index of the array]
ARRAY=[#-# jobs to run]

# SBATCH OPTIONS
PARTITION=[which partition to submit to]
RESERVATION=[targeted set of nodes]
'
}

#### GLOBALS ####
SACCT=/usr/bin/sacct
SBATCH=/usr/bin/sbatch
MaxArraySize=$(/usr/bin/scontrol show config | sed -n '/^MaxArraySize/s/.*= *//p')

# Required SACCT arguments and idexes to them
SACCT_ARGS+=("-XP --noheader") 
export SACCT_FORMAT='jobid,state,partition,submit,start,end,jobidraw'
JOBID=0			# get the jobid from jobid_jobstep
JOBSTEP=1		# get the jobstep from jobid_jobstep
JOBSTATE=1		# Job state
PARTITION=2		# Where is the job running?
SUBMIT_TIME=3		# Submit time
START_TIME=4		# Start time
END_TIME=5		# End time

#### Helper funtions for printing ####

# print a tab separated list of jobs in five columns	
pretty_print_tabs() {
	list=($@)
	
	count=1
	mod=5
	for l in ${list[@]}; do
		printf "\t$l"
		if (( $count % $mod == 0 )); then
			printf "\n"
		fi
		((count+=1))
	done
	printf "\n"
}

# print a comma separated list of jobs
# helpful for knowing which jobs to rerun
pretty_print_commas() {
	list=($@)

	count=0
	for l in ${list[@]}; do
		printf "$l"
		((count+=1))
		if (( $count < ${#list[@]} )); then
			printf ","
		fi
	done
	printf "\n"
}

# sort and print a list of jobs
print_sorted_jobs() {
	list=($@)

    sorted=( $(
		for l in ${list[@]}; do
			IFS='_' read -ra split <<< "$l"
			echo ${split[1]}
		done | sort -nu
		) )
	pretty_print_commas ${sorted[@]}
}

# get the list of jobs
get_sorted_jobs() {
	runs=($@)

	list=()
	for run in ${runs[@]}; do
		IFS='|' read -ra split <<< "$run"
		jobid=${split[$JOBID]}
		list+=($jobid)
	done

    sorted=( $(
		for l in ${list[@]}; do
			IFS='_' read -ra split <<< "$l"
			echo ${split[0]}
		done | sort -nu
		) )
}

# convert value of seconds to a time
convertsecs() {
	((h=${1}/3600))
	((m=(${1}%3600)/60))
	((s=${1}%60))
	printf "%02d:%02d:%02d\n" $h $m $s
}

# use the SUBMIT, START, and END times from sacct to calculate
# the average wall time and run time for a set of jobs
run_times() {
	runs=($@)

	sum_wall_time=0
	sum_elapsed=0
	for run in ${runs[@]}; do
		IFS='|' read -ra split <<< "$run"
		submit_=$(date --date=${split[$SUBMIT_TIME]} +%s )
		start_=$(date --date=${split[$START_TIME]} +%s )
		end_=$(date --date=${split[$END_TIME]} +%s )
		sum_elapsed=$(( sum_elapsed + $(( $end_ - $start_ )) ))
		sum_wall_time=$((sum_wall_time + $(( $end_ - $submit_ )) ))
	done

	avg_elapsed=$(($sum_elapsed / ${#runs[@]}))
	avg_wall_time=$(($sum_wall_time / ${#runs[@]}))

	echo "	Avg Run Time: $(convertsecs $avg_elapsed)"
	echo "	Avg Wall Time: $(convertsecs $avg_wall_time)"
}

#### SACCT PARSING ####
# Use SACCT to load the jobs
COMPLETED=()
FAILED=()
TIMEOUT=()
RUNNING=()
PENDING=()
OTHER=()

parse_sacct_jobs() {
   
    if [[ -n $CONFIG ]]; then
        # Set SACCT_ARGS from CONFIG
        source $CONFIG
        if [[ -n $JOB_IDS ]]; then
            SACCT_ARGS+=("--jobs=${JOB_IDS}")
        fi
        if [[ -n $BATCH_NAME ]]; then
            SACCT_ARGS+=("--name=${BATCH_NAME}")
        fi
        if [[ -n $JOB_DATE ]]; then
            SACCT_ARGS+=("-S ${JOB_DATE}")
        fi
    fi
    
    echo "Finding jobs using: $SACCT ${SACCT_ARGS[@]}"
    all=($($SACCT ${SACCT_ARGS[@]}))
    if [[ ${#all[@]} -eq 0 ]]; then
	    echo "No jobs found with these sacct args"
    else
        echo "Jobs: $(get_sorted_jobs ${all[@]})"
    fi
    
    # Split the job list by STATE
    for run in ${all[@]}; do
	    IFS='|' read -ra split <<< "$run" # split the sacct line by '|'
        state=${split[$JOBSTATE]}
        if [[ $EXCLUDE -eq 1 ]]; then
            # don't process excluded jobs
		    IFS='_' read -ra job <<< "${split[$JOBID]}"
	        jobid=${job[$JOBID]}
		    if [[ "${EXCLUDED[@]}" =~ "${jobid}" ]]; then
			    continue
		    fi
	    fi
    
        if [[ $state = "COMPLETED" ]]; then
            COMPLETED+=($run)
        elif [[ $state = "FAILED" ]]; then
            FAILED+=($run)
        elif [[ $state = "TIMEOUT" ]]; then
            TIMEOUT+=($run)
        elif [[ $state = "RUNNING" ]]; then
            RUNNING+=($run)
        elif [[ $state = "PENDING" ]]; then
            PENDING+=($run)
        else
            OTHER+=($run)
        fi
    
    done
}

#### CONFIG MODE ####

append_ids() {
    source $CONFIG
    if [[ -z $JOB_IDS ]]; then
        # Add the job ids env var if missing
        if [[ $(grep "JOB_IDS" $CONFIG) ]]; then
            sed -i "s/JOB_IDS=.*/JOB_IDS=${IDS}/" $CONFIG
        else
            echo "JOB_IDS=${IDS}" >> $CONFIG
        fi
    else
        # Add the job ids in sorted order
        JOB_IDS=$(echo $JOB_IDS,$IDS)
        JOB_IDS=$(echo $JOB_IDS | tr , "\n" | sort | uniq | tr "\n" , ; echo )
        sed -i "s/JOB_IDS=.*/JOB_IDS=${JOB_IDS}/" $CONFIG
    fi

    if [[ -z $JOB_DATE ]]; then
        # Add the job date if it is missing
        JOB_DATE="$(date +%Y-%m-%dT%H:%M)"
        if [[ $(grep "JOB_DATE" $CONFIG) ]]; then
            sed -i "s/JOB_DATE=.*/JOB_DATE=${JOB_DATE}/" $CONFIG
        else
            echo "JOB_DATE=${JOB_DATE}" >> $CONFIG
        fi
    fi

}

append_config()
{
    if [[ $# -eq 0 ]]; then
        usage "config"
        return 1
    fi

    while test $# -ne 0; do
        case $1 in
        --jobids) shift
            if [[ -z $1 ]]; then
                usage "config"
                return 1
            fi
            IDS=$1
        ;;
        --config) shift
            if [[ -z $1 || ! -e $1 ]]; then
                usage "config"
                return 1
            fi
            CONFIG=$(readlink -f $1)
        ;;
        *) usage "config"
             return 1
        ;;
        esac
        shift
    done
    append_ids $IDS
}

create_config() {
    if [[ $# -eq 0 ]]; then
        usage "config"
        return 1
    fi

    while test $# -ne 0; do
        case $1 in
        --jobids) shift
            JOB_IDS=$1
        ;;
        --jobname) shift
            if [[ -z $1 ]]; then
                usage "config"
                return 1
            fi
            JOB_NAME=$1
            ;;
        --jobdir) shift
            if [[ -z $1 || ! -e $1 ]]; then
                usage "config"
                return 1
            fi
            JOB_DIR=$1
        ;;
        *) usage "config"
            return 1
        ;;
        esac
        shift
    done

echo "Creating config file ${JOB_NAME}_CONFIG"

JOB_DATE="$(date +%Y-%m-%dT%H:%M)"
cat << EOT > ${JOB_NAME}_CONFIG
BATCH_NAME=$JOB_NAME
JOB_IDS=$JOB_IDS
BATCH_DIR=$JOB_DIR
JOB_DATE=$JOB_DATE

EOT

}

reset_config() {
    if [[ -z $1 || ! -e $1 ]]; then
       usage "config"
       return 1
    fi
    CONFIG=$(readlink -f $1)
    source $CONFIG
    
    echo "Resetting $BATCH_NAME"

    $DEBUG sed -i "s/JOB_IDS=.*/JOB_IDS=/" $CONFIG
    $DEBUG sed -i "s/JOB_DATE=.*/JOB_DATE=/" $CONFIG
    
    $DEBUG sed -i "s/NEXT_RUN_ID=.*//" $CONFIG
    $DEBUG sed -i "s/LAST_RUN_ID=.*//" $CONFIG
    
    return 0
}

config_mode() {
    if [[ $# -eq 0 ]]; then
        usage "config"
        return 1
    fi
        
    while test $# -ne 0; do
        case $1 in
        --append) append_config ${@:2:$#-1} 
            return $?
        ;;
        --create) create_config ${@:2:$#-1}
            return $?
        ;;
        --reset) reset_config ${@:2:$#-1}
            return $?
        ;;
        *) usage "config"
            return 1
        ;;        
        esac
    done

}
    
#### REPORT MODE ####

handle_completed() {
	runs=($@)

	if [ $VERBOSE -eq 1 ]; then
	    run_times ${runs[@]}
	    if [[ -n $SMANAGE_EXT_SOURCE ]]; then
            _ext_handle_completed ${runs[@]}
        fi
        echo ""
	fi	
	
}

handle_failed() {
    runs=($@)
	list=()	
	for run in ${runs[@]}; do
	   	IFS='|' read -ra split <<< "$run"
		list+=(${split[$JOBID]})
	done

    echo "Rerun these jobs:"
	pretty_print_tabs ${list[@]}
    print_sorted_jobs ${list[@]}

    if [[ $VERBOSE -eq 1 ]]; then
	    run_times ${runs[@]}
	    if [[ -n $SMANAGE_EXT_SOURCE ]]; then
            _ext_handle_failed ${runs[@]}
        fi
	fi	

	echo ""
}

handle_running() {
	runs=($@)

	if [ $VERBOSE -eq 1 ]; then
	    list=()	
	    for run in ${runs[@]}; do
	    	IFS='|' read -ra split <<< "$run"
	    	list+=(${split[$JOBID]})
	    done

	    pretty_print_tabs ${list[@]}
	    print_sorted_jobs ${list[@]}

	    echo ""
	fi
}

handle_pending() {
	runs=($@)

	list=()
	for run in ${runs[@]}; do
		IFS='|' read -ra split <<< "$run"
		list+=(${split[$JOBID]})
	done

	if [ $VERBOSE -eq 1 ]; then
	    echo "Pending jobs: "
	    pretty_print_tabs ${list[@]}
	fi

	echo ""
}

handle_other() {
	runs=($@)

	list=()	
	for run in ${runs[@]}; do
		IFS='|' read -ra split <<< "$run"
		jobid=${split[$JOBID]}
		state=${split[$JOBSTATE]}
		list+=("$jobid: $state")
	done
	pretty_print_tabs ${list[@]}
}

report_mode() {
    local opts="--config --sacct"
    
    while test $# -ne 0; do
        case $1 in
        --config) shift
            if [[ -z $1 || ! -e $1 ]]; then
                usage "report"
                return 1
            fi
            CONFIG=$(readlink -f $1)
            shift
        ;;
        --sacct) shift
            while [[ -n $1 && ! $opts =~ $1 ]]; do
                SACCT_ARGS+=($1)
                shift
            done
        ;;
        *)
            usage "report"
            return 1
        ;;        
        esac
    done
    
    parse_sacct_jobs
    
    echo "${#COMPLETED[@]} COMPLETED jobs"
    if [[ ${#COMPLETED[@]} > 0 && $VERBOSE -eq 1 ]]; then
        handle_completed ${COMPLETED[@]}
    fi
    
    echo "${#FAILED[@]} FAILED jobs"
    if [[ ${#FAILED[@]} > 0 && $VERBOSE -eq 1 ]]; then
    	handle_failed ${FAILED[@]}
    fi
    
    echo "${#TIMEOUT[@]} TIMEOUT jobs"
    if [[ ${#TIMEOUT[@]} > 0 && $VERBOSE -eq 1 ]]; then
        handle_failed ${TIMEOUT[@]}
    fi
    
    echo "${#RUNNING[@]} RUNNING jobs"
    if [[ ${#RUNNING[@]} > 0 && $VERBOSE -eq 1 ]]; then
        handle_running ${RUNNING[@]}
    fi
    
    echo "${#PENDING[@]} PENDING jobs"
    if [[ ${#PENDING[@]} > 0 && $VERBOSE -eq 1 ]]; then
        handle_pending ${PENDING[@]}
    fi
    
    if [[ ${#OTHER[@]} > 0 ]]; then
    	echo "${#OTHER[@]} jobs with untracked status"
    	if [[ $VERBOSE -eq 1 ]]; then
    		handle_other ${OTHER[@]}
    	fi
    fi

    return 0
}


#### SUBMIT MODE ####

set_config_value() {
PARAM=$1
VALUE=$2

if [[ $(grep $PARAM $CONFIG) ]]; then
    $DEBUG sed -i "s/${PARAM}=.*/${PARAM}=${VALUE}/" $CONFIG
else
    $DEBUG echo "${PARAM}=${VALUE}" >> $CONFIG
fi

}

submit_batch() {
    if [[ -n $CONFIG ]]; then
        config_arg="--config $CONFIG"
    fi
    
    if [[ -z $BATCH_DIR ]]; then
        BATCH_DIR=$PWD
    fi
    if [ -z $BATCH_NAME ]; then
        BATCH_NAME=$(basename $BATCH_DIR)
    fi

    OUTPUT=$($DEBUG $SBATCH -D $BATCH_DIR --job-name="$BATCH_NAME" 
                    $array_arg $reservation_arg
                    $SBATCH_SCRIPT $SBATCH_SCRIPT_ARGS
                    $NEXT_RUN_ID)

    if [[ $? -ne 0 ]]; then
        echo ERROR: $OUTPUT
        if [[ -n $NEXT_RUN_ID ]]; then
            set_config_value "NEXT_RUN_ID" $NEXT_RUN_ID
            set_config_value "LAST_RUN_ID" $LAST_RUN_ID
        fi
        exit 1
    fi

    # read the new job number from the sbatch output
    echo $OUTPUT
    IFS=" " read -ra split <<< "$OUTPUT"
    job_id=${split[3]}

    # create a report script -- only do this once
    if [[ -z $CONFIG ]]; then
        $DEBUG config_mode --create --jobdir $output_dir --jobname ${JOB_NAME} --jobids $job_id
    else
        $DEBUG config_mode --append --config $CONFIG --jobids $job_id
    fi
    
}

reserve_submit_batch() {
  curr_max_id=-1
  num_to_run=$RESERVE

  runs+=${PENDING[@]}
  runs+=${RUNNING[@]}
  runs+=${COMPLETED[@]}

  if [[ ${#runs[@]} -gt 0 ]]; then

    num_pending=0
    for run in ${runs[@]}; do
        IFS='|' read -ra split <<< "$run"
        IFS='_' read -ra job <<< "${split[$JOBID]}"
        jobstep=${job[$JOBSTEP]}
        # Pending jobs may look like [###-###]
       if [[ $jobstep =~ ^(\[)([[:digit:]]+)-([[:digit:]]+)(\])$ ]]; then
            # Get how many are pending
            leftjobstep=( $(echo "$jobstep" | tr -d '[[:alpha:]]' | cut -d '-' -f 1) )
            rightjobstep=( $(echo "$jobstep" | tr -d '[[:alpha:]]' | cut -d '-' -f 2) )
            num_pending=$((num_pending + rightjobstep - leftjobstep))
            # Get the right-hand value from the pending job list
            jobstep=$rightjobstep
        fi
        if [[ $jobstep -gt $curr_max_id ]]; then
           curr_max_id=$jobstep
        fi
    done
    
    # use queued runs to calculate the next array of runs
    num_queued=$((${#RUNNING[@]} + num_pending))
    num_to_run=$(($RESERVE - $num_queued))

    if [[ $num_to_run -lt 1 ]]; then
        echo "No jobs submitted for ${BATCH_NAME}. The queue is full with $num_queued of $RESERVE runs"
        return 0
    fi 

    if [[ -n $USE_SARRAY_IDS ]]; then
        NEXT_RUN_ID=$(($curr_max_id + 1))
        LAST_RUN_ID=$(($NEXT_RUN_ID + $num_to_run))
    elif [[ -n $LAST_RUN_ID ]]; then
        NEXT_RUN_ID=$(($LAST_RUN_ID + 1))
        LAST_RUN_ID=$(($NEXT_RUN_ID + $num_to_run))
    else
        NEXT_RUN_ID=0
        LAST_RUN_ID=$(($NEXT_RUN_ID + $num_to_run))
    fi
    if [[ $LAST_RUN_ID -gt $MAX_ID ]]; then
        LAST_RUN_ID=$MAX_ID
    fi

    if [[ $NEXT_RUN_ID -ge $MAX_ID ]]; then
        echo "Ding! Jobs named ${BATCH_NAME} are done!"
        return 0
    fi

    if [[ -n $USE_SARRAY_IDS ]]; then
        idx=$(($NEXT_RUN_ID % $MaxArraySize))
        idy=$(($LAST_RUN_ID % $MaxArraySize))
        if [[ $idx -eq $idy ]]; then
            ARRAY="$idx"
        else
            ARRAY="$idx-$idy"
        fi
    else
        if [[ $num_to_run -eq 1 ]]; then
            ARRAY="0"
        else
	        ARRAY="0-${num_to_run}"
        fi
    fi
  fi
    
  echo "Submitting jobs $NEXT_RUN_ID - $LAST_RUN_ID as $ARRAY"
  submit_batch
}

submit_batch_jobs() {
    if [[ -n $RESERVE ]] && [[ -n $MAX_ID ]]; then
        # use the RESERVE and MAX_ID to run the batch
        reserve_submit_batch
    else
        echo "Submitting jobs $ARRAY"
        submit_batch
    fi

    return $?
}

submit_mode() {
    if [[ $# -eq 0 ]]; then
        usage "submit"
        return 1
    fi

    local opts="--config --sacct --sbatch"
    while test $# -ne 0; do
        case $1 in
        --config) shift
            if [[ -z $1 || ! -e $1 ]]; then
                usage "submit"
                return 1
            fi
            CONFIG=$(readlink -f $1)
        ;;
        --sacct) shift
            while [[ -n $1 && ! $opts =~ $1 ]]; do
                SACCT_ARGS+=($1)
                shift
            done 
        ;;
        --sbatch) shift
            while [[ -n $1 && ! $opts =~ $1 ]]; do        
                SBATCH_ARGS+=($1)
                shift
            done 
        ;;      
        *)
            usage "submit"
            return 1
        ;;        
        esac
    done

    submit_batch_jobs

    return $?

}

#### MAIN ####

DEBUG=
VERBOSE=
HELP=

# print out help if no args provided
if [[ -z $1 ]]; then
    usage
    exit 0
fi

# handle smanage options
modes="report reset submit config"
MODE=
while [[ $# -gt 0 ]]; do
    case $1 in
    -h|--help) HELP=1 ;; 
    -d|--debug) DEBUG=/usr/bin/echo ;;
    -v|--verbose) VERBOSE=1 ;;
    esac
    # the MODE must be the first parameter after opts
    if [[ $modes =~ $1 ]]; then
       MODE=$1
       break
    fi
    shift
done

if [[ -n $HELP ]]; then
    usage "$MODE"
    exit 0
fi

# the remaining arguments get passed whichever MODE is specified
case "$MODE" in
    config) config_mode ${@:2:$#-1} ;;
    report) report_mode ${@:2:$#-1} ;;
    reset)  reset_mode  ${@:2:$#-1} ;;
    submit) submit_mode ${@:2:$#-1} ;;
    *) usage ;; 
esac
exit $?

# vim: sw=4:ts=4:expandtab
