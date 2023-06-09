#!/bin/bash

if [ -z "$1" -o "$1" == "-h" -o "$1" == "--help" ]; then
    echo '''Usage: test_images.sh path/to/test_images DIR DIR ...

path/to/test_images

DIR

    A directory that the test user should have read/write access
to that should be tested.

Example:
$ test_images.sh $WORK/test_images $HOME $SCRATCH /tmp
'''
    exit 1
fi

CONTAINER_RUNTIME="apptainer"

function testC() {
    if [[ "$( eval $2 )" == *"$3"* ]]
    then
        echo "PASSED - $1"
        NP=$((NP+1))
    else
        echo "FAILED - $1"
        echo "$2 does not produce '$3'"
        NF=$((NF+1))
    fi
}

function testV() {
    if [ "$( eval $2 )" == "$3" ]
    then
        echo "PASSED - $1"
        NP=$((NP+1))
    else
        echo "FAILED - $1"
        echo $2 != "$3"
        NF=$((NF+1))
    fi
}

function testO() {
    if [[ -z $( diff <( $2 2>/dev/null) <( $3 2>/dev/null) ) ]]
    then
        echo "PASSED - $1"
        NP=$((NP+1))
    else
        echo "FAILED - $1"
        diff <( $2 ) <( $3 )
        echo $2 != "$3"
        NF=$((NF+1))
    fi
}

function testT() {
    if bash -c "$2" &>/dev/null
    then
        echo "PASSED - $1"
        NP=$((NP+1))
    else
        echo "FAILED - $1"
        NF=$((NF+1))
    fi
}

function testF() {
    if $2 &> /dev/null
    then
        echo "FAILED - $1"
        echo "$2"
        NF=$((NF+1))
    else
        echo "PASSED - $1"
        NP=$((NP+1))
    fi
}

function verlte {
    # Check to see if V1 <= V2
    #
    # Usage: verlte 2.3.1 2.2.1
    # 1
    [  "$1" = $(echo -e "$1\n$2" | sort -V | head -n1) ]
}

function checkimg() {
    img=$1
    has_ml=0
    has_mpi=0

    [[ $img == *"-pt"* ]] && has_ml=1
    [[ $img == *"-impi"* ]] && has_mpi=1 && MPI_TYPE="impi"
    [[ $img == *"-mvapich"* ]] && has_mpi=1 && MPI_TYPE="mvapich"

    if [[ $has_ml -eq 1 ]]; then
        ML=1
    fi
    if [[ $has_mpi -eq 1 ]]; then
        MPI=1
    fi
}

if ! command -v $CONTAINER_RUNTIME &>/dev/null; then
    echo "ERROR: $CONTAINER_RUNTIME is not loaded! Run 'module load tacc-$CONTAINER_RUNTIME'."
    exit 1
fi

IMGDIR=$1
cd ${IMGDIR}

# redirect output to a log file as well
ts=$(date +%Y%m%d_%H%M%S)
exec > >(tee -i test_images-${ts}.log) 2>&1

for IMG in $(ls -1 *.sif)
do
    ML=0
    MPI=0
    MPI_TYPE=""
    NP=0
    NF=0

    filebase="${IMG%%.sif}"
    echo "--------------------------------------------------"
    echo "## TESTING - ${filebase} ##"

    checkimg "$IMG"
    # Test user
    testV "$USER in apptainer image" "apptainer exec $IMG whoami" "$USER"

    # Test mounted filesystems
    for f in ${@:2} /tmp
    do
        testO "native $f is mounted in image" "apptainer exec $IMG /bin/ls -U $f" "/bin/ls -U $f"
    done

    # Test writing files
    TF="testFile$((1000 + RANDOM % 9999))"
    for f in ${@:2} /tmp
    do
        testT "create $f/$TF inside container" "apptainer exec $IMG touch $f/$TF"
        testT "find $f/$TF outside container" "ls $f/$TF"
        testT "delete $f/$TF inside container" "apptainer exec $IMG rm $f/$TF"
        testF "cannot find $f/$TF outside container" "ls $f/$TF && rm $f/$TF"
    done

    # Test python version
    testV "Python version 3.9.16 in image" "apptainer exec $IMG python -V" "Python 3.9.16"

    # Run ML tests (if applicable)
    if [[ $ML -eq 1 ]]; then
        # test pytorch
        testC "Load pytorch and find GPU" "apptainer exec --nv $IMG python torch_test.py 2>/dev/null" "CUDA available: True"

        # test tensorflow
        testC "Load tensorflow and find GPU" "apptainer exec --nv $IMG python tf_test.py 2>/dev/null" "GPU available: True"
    fi

    # Run MPI tests (if applicable)
    if [[ $MPI -eq 1 ]]; then
        MPI_ENV=""
        if [[ $MPI_TYPE == "mvapich" ]]; then
            MPI_ENV="MV2_ENABLE_AFFINITY=0 MV2_SMP_USE_CMA=0 MV2_USE_THREAD_WARNING=0"
        fi
        testC "Load mpi4py and calculate pi with 1 task" "$MPI_ENV ibrun -n 1 apptainer run $IMG python pi-mpi.py 100000" "Final Estimate:"
        testC "Load mpi4py and calculate pi with 8 tasks" "$MPI_ENV ibrun -n 8 apptainer run $IMG python pi-mpi.py 100000" "Final Estimate:"
    fi

    # Summary
    echo -e "\n## Summary - ${filebase} ##"
    echo "$NP tests passed"
    echo "$NF tests failed"
    echo ""
done
