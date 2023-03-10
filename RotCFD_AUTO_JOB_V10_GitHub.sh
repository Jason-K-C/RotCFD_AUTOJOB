#!/bin/bash
##!/bin/bash -x    # Use this for de-bugging if somethings going wrong.   Outputs every command to the PBS .o file. 

##############################################################################
# This section covers PBS job setup on NAS supercomputer and output files.   #
##############################################################################

# Gives the script a name that will show up in the queue if using a PBS job scheduler. 
#PBS -N RotCFD_AUTOJOB

# If using cas_gpu (NAS), must replace 'nThreads=' must have 'nThreads=96' in every instance of the script. 
# Request Cas GPU node(s), 48 CPUs total, taking entire node, limit memory request to ~80% total available per NAS instruction. 
##PBS -l select=1:ncpus=48:ngpus=4:mem=300g:mpiprocs=1:ompthreads=48:model=cas_gpu

# If using sky_gpu (NAS), must replace 'nThreads=96' with 'nThreads=72' in every instance of the script. 
# Request Sky GPU node(s), 36 CPUs total, taking entire node, limit memory request to ~80% total available per NAS instruction. 
#PBS -l select=1:ncpus=36:ngpus=4:mem=300g:mpiprocs=1:ompthreads=36:model=sky_gpu

# NAS relevant settings. Sole use of node, maximum walltime for v100 queue=24hrs, 3 qsub jobs allowed running simultaneously. 
#PBS -l place=scatter:excl
#PBS -l walltime=24:00:00 
#PBS -q v100
#  Join output and error streams into a single file
#PBS -j oe  
#  Email if job aborts
#PBS -m ba

#INFOFILE will contain job start date and time, and the node it is running on.
INFOFILE=RotCFD_job_info_1.txt
#INFOFILE2 contains the re-directed output from the script. Used to track script progress, etc. 
INFOFILE2=RotCFD_AUTOJOB_LogFile1.txt
#There is an 'ERROR.log' in the working directory ${ROTCFD_JOB_PATH} that tracks any errors, or reports any cases that did not fully converge or hung up. 

module load comp-intel mpi-hpe
echo -e "Job started at:" $(date) > "${INFOFILE}"
echo -e "\tRunning on: $(hostname)" >> "${INFOFILE}"

# This bracket re-directs from here down into the LogFile. (INFOFILE2)
{

#########################################################################################################
# RotCFD_AUTOJOB Rev10 processing script.
# Written by Jason Cornelius and Kirk Heller for Penn State University
# Revisions by Jason Cornelius and Ethan Romander, NASA Ames Research Center. 
# Features:  Auto job creation, parallelization across multiple GPUs, convergence checks, re-start if 
#    		 needed, clean-up.   
# March 2023
#########################################################################################################

# Modify the below when setting up script to run a new model. -> Contact Jason Cornelius with questions. 
# Variable Declarations and Run Parameters. 
# Check Matrix Arrays:  SA_DEG, V_MAG, and RPM arrays.
# Check Run Parameters: N_Rotors, TGRID, TGRID_Layers, ITERATION_GRID.  
# Check SA_ITHALT, V_ITHALT, and RPM_ITHALT (for partial runs, otherwise=-1).
# Check NOSJ: number of jobs running per GPU. Must do initial testing with this parameter to determine maximum throughput while retaining node stability.  
# Check Flags: CLEANUP, and CPBIT. 
# Check Directories: RotCFD_JOB_PATH, RotCFD 'bin' path, BASEDIR, CPBASEDIR, CP_PATH.   #These may change depending on where the orgiinal RotCFD files are located, or where you want to copy them to. 

# Matrix Arrays
SA_DEG=(-90 -75 -60 -45 -30 -15 0 15 30 45 60 75 90)	#Shaft angle SA Array in Degrees. (13)
V_MAG=(5 7.5 10) 										#Velocity Magnitude Array. (3)
RPM=(500 750 1000)										#RPM Array. (3)
TGRID=(0 1 2 3 4 5)										#TGRID array, for telling the script how long to run (physical simulation time, not wall-clock). 
TGRID_LAYERS=(1 2 4 6 8 10)								#TGRID layers array, for re-initializing TGRID_TRACKER on job re-starts caused by TERMINATE or node close-out). 
ITERATION_GRID=(1000 2000 3000 4000 4950)				#ITERATION_GRID holds the number of iterations that will be cycled through each layer of the RotCFD .Tgrid input file. It starts low and increases as needed for divergence due to compressibiilty. 

# Run Parameters
# Start points in above matrices. (0-indexed, so first value in each matrix corresponds to index 0) 
declare -i S=0										#SA Array indexer.
declare -i V=0										#V_MAG Array indexer.
declare -i R=0										#RPM Array indexer.
# Stop-points in above matrices. (0-indexed) 
declare -i SA_ITHALT=-1								#Position in SA array to halt tasks (for partial runs). Full run is final position in SA Array +1 (0-indexed).
declare -i V_ITHALT=-1								#Position in V array to halt tasks (for testing purposes, default is a negative # so as to not be triggered.
declare -i RPM_ITHALT=-1							#Position in RPM array to halt tasks (for testing purposes, default is a negative # so as to not be triggered.
# Number of rotors, sims / GPU, BASEDIR_ITERATION. 
declare -i N_Rotors=2								#Number of rotors in RotCFD model. Used for checking convergence. 
declare -i NOSJ1=2									#Variable instructing Number of Simultaneous Jobs we allow to run on GPU1

# Flags
CLEANUP="TRUE"										#Enables file cleanup to conserve space. (TRUE or FALSE).  If TRUE, will delete the final restart file and simulation grid.  Suggest leaving FALSE, unless trying to conserve space.
CPBIT="TRUE"										#Variable to enable or disable moving completed simulations to storage Directory (CP_PATH).

# Directories. 
ROTCFD_JOB_PATH="/RunDirectory"						#Path to working directory containing RotCFD root folder (BASEFOLDER) directory to duplicate.
ROTCFD_BIN_PATH="/rotcfd_k06/bin/"					#Path to the RotCFD binary directory where the RotCFD executables are. On NAS, Ethan may need to give you access to this.
BASEDIR="BASEFOLDER"								#Name of base directory that will be duplicated. This is the name of the original base RotCFD directory that will be copied and modified. 
CPBASEDIR="COAX"									#Name of iterative basefile name (prefix that will be used to duplicate BASEDIR).
CP_PATH="/RotCFD_AUTO_JOB/Completed/"				#Location of where results are to be copied to.  (second internal hard drive, for example). 









# Advanced Variables - Shouldn't require any modification.  Supernerds only below this line.

 
declare -a ACTIVEJOB										#Array that holds names of current running jobs.
declare -a TGRID_TRACKER									#Array that monitors the current time grid, so the script knows which TGRID to substitute upon subsequent automated restarts.
declare -a ITERATION_GRID_TRACKER							#Array that monitors the current iteration grid, so the script knows which ITERATION_GRID to substitute upon subsequent automated restarts. 
declare -i SA_SIZE="${#SA_DEG[@]}-1"						#Size of SA Array -1 since 0-indexed.
declare -i V_SIZE="${#V_MAG[@]}-1"							#Size of V_MAG Array -1 since 0-indexed.
declare -i RPM_SIZE="${#RPM[@]}-1"							#Size of RPM Array -1 since 0-indexed.
declare -i TGRID_SIZE="${#TGRID[@]}-1"						#Size of TGRID Array -1 since 0-indexed. 
declare -i ITERATION_GRID_SIZE="${#ITERATION_GRID[@]}-1"	#Size of ITERATION_GRID Array -1 since 0-indexed. 
declare -i BASEDIR_ITERATION=2500							#This specifies the number used in each layer of .Tgrid within the basefolder.  Changes depending on RotCFD model. Suggest using Jason's Example RotCFD folder and leaving this value as is. 
TSPEED=0													#Variable to hold Tip Speed Calculations (floating point).

NEWCASERUNFLAG="TRUE"										#Boolean flag to continue interations.
RUNFLAG="TRUE"												#Boolean flag to continue interations.
COMPRESSIBILITY_FLAG="FALSE"								#Boolean flag to determine if compressibility was detected. 
declare -i TASKS=0											#Variable to keep track of number of jobs running. Initializing to 0.
declare -i TIMER=60											#Time (in Seconds) to wait before checking NOSJ again.
declare -i TIMER2=10										#Time (in Seconds) to wait before deleting the re-start file after commanding a re-start.
declare -i JOBTIMER=300										#Time (in seconds) to wait before considering a job, via ACTIVE_FILE modification time, to be hung, maybe diverged (?).

ACTIVE_FILE="/Rotor_Performance/Performance/TrimLog2.out"	#Sub-directory path and file of ROTCFD_JOB_PATH directory that is being written to. This output file is what is monitored to determine job activity.
ERROR_LOG="${ROTCFD_JOB_PATH}/ERROR.log"					#Writes any errors from this script into the ERROR.log file within the main directory the cases are being run in. 
RESTART_FILE="/Restarts/CoAxial_Batch.Rst"					#Location of restart file, in subdirectory of ROTCFD_JOB_PATH directory, that may be cleaned out to conserve space.
RESTART_FILE_MID_RUN="/Restarts/Restart_History/CoAxial_Batch.Rst"			#Location of restart file, in subdirectory of ROTCFD_JOB_PATH directory, that may be cleaned out to conserve space.
GEOM="/Solver_Input/CoAxial_Batch.RtrGeom"					#Location of RtrGeom file, in subdirectory of ROTCFD_JOB_PATH directory, that may be cleaned out to conserve space.
GRID_OUTPUT="/Grid_Output/"									#Subdirectory ROTCFD_JOB_PATH directory containing grid geometry files that may be cleaned out to conserve space. 

declare -i ITERATION=0										#Don't touch this. Initializing script. 
DIR_NAME=""													#Don't touch this. Internal variable to hold current directory name of running task. It's here for completionist sake. Value assigned at start of iteration.


############################################################################################
# Operation: Get_GPU_DeviceIDs                                                             #
# Purpose: Creates an array of the DeviceID numbers for each new node the script runs on.  #
# 			These device IDs are how the script coordinates the jobs with various GPUs     #
#   		For now, script can only run on 1 node at a time. (4 GPUs)                     #
############################################################################################

get_GPU_deviceids() {
   #Use nvidia-smi to find available CUDA devices and grab their PCI Bus IDs.
   #Substitude ":" and "." in each Bus ID with " " and loop on each device.
   nvidia-smi -q | grep "Bus Id" | tr ":." " " | while IFS="\n" read id; do
   	  #Repack the ID as an array to split on spaces
      id=( $id )
      #Build Device ID integer from individual bytes.
      deviceId=$(( (0x${id[3]}<<16) + (0x${id[4]}<<8) + 0x${id[5]} ))
      printf "%d\n" $deviceId
   done
}

deviceIDs=( $(get_GPU_deviceids) )
echo "${deviceIDs[*]}"
declare -i DeviceIDs_SIZE="${#deviceIDs[@]}"			#Size of Device ID array.
declare -i NOSJ=${NOSJ1}*${DeviceIDs_SIZE}  			#Variable instructing Number of Simultaneous Jobs the script should allow to run. (#Jobs/GPU  * #GPUs = Total allowed)


###############################################################################
# Function: Convergence_Check                                                 #
# Purpose: Checks for convergence of a specifc run in activejob array.        #
# 			If passes, cleans up case.  If fails, re-starts case. 			  #
# Can tighten or loosen 'tolerance' if desired.  Recommend leave as is.       #
###############################################################################

function Convergence_Check {

local -r RESTART_JOB=$1	
#echo "Checking convergence of: ${RESTART_JOB}"

FILE=${ROTCFD_JOB_PATH}/${ACTIVEJOB[$i]}/${ACTIVE_FILE}					#Points to the TrimLog2.out file to check convergence of each rotor thrust and power. 
convergesteps=100														#Decrease this for de-bugging, set to 100 for real runs.
tolerance=0.25															#Tolerance (in percent) that anything greater than will flag a failed convergence.  Decrease this for de-bugging, set to 0.25 for real runs. 

FSIZE=$( wc -l < ${FILE} ) #Returns total number of lines in file.  	#This is the total number of lines in the text file. (last blank line not counted)

((LINENUM=${FSIZE}-(3+2*${N_Rotors}) ))									#This sets LINENUM to be Rotor1 row of output (not final condensed output)

((LINENUM2=${LINENUM}-(N_Rotors*${convergesteps}) ))					#This sets LINENUM2 to be Rotor1 row of output number of 'convergesteps' back from last.  (i.e. 4000 - '100' = 3900) 

#echo "Final thrust is: " $( awk -v NUM="$LINENUM" 'NR==NUM{ print; exit }' ${FILE} |awk -F " " '{print $4}' ) #Grabs Line Number "NR==" and returns value | Break apart string based on spaces and return 4th element.
#echo "Final power is: "$( awk -v NUM="$LINENUM" 'NR==NUM{ print; exit }' ${FILE} |awk -F " " '{print $16}' )

convergence_flag="TRUE" 								#Initializing the convergence flag 
ConvergenceRUNFLAG="TRUE" 								#Initializing the convergence run flag 
declare -i rotor_tracker=1	

while [[ "${ConvergenceRUNFLAG}" == "TRUE" && "${convergence_flag}" == "TRUE" ]]; do	

    echo "Checking convergence for rotor # " ${rotor_tracker}
    thrust_final=$( awk -v NUM="$LINENUM" 'NR==NUM{ print; exit }' ${FILE} |awk -F " " '{print $4}' )
    thrust_convergecheck=$( awk -v NUM="$LINENUM2" 'NR==NUM{ print; exit }' ${FILE} |awk -F " " '{print $4}' )
    #echo "Final thrust: " ${thrust_final}
    #echo "Convergence check thrust: " ${thrust_convergecheck}
    
    convergence_check=$( awk -v t_final=${thrust_final} -v t_converge=${thrust_convergecheck} 'BEGIN {printf "%.4f", 100*((t_final - t_converge) / t_converge) }' )	# Calculates thrust convergence
    echo "Convergence thrust delta (%): " ${convergence_check}
    
    if [[ "${convergence_check}" > "${tolerance}" ]]; then
		convergence_flag="FALSE"
		echo "Rotor " ${rotor_tracker} "thrust convergence failed." 
    fi
    
    power_final=$( awk -v NUM="$LINENUM" 'NR==NUM{ print; exit }' ${FILE} |awk -F " " '{print $16}' )
    power_convergecheck=$( awk -v NUM="$LINENUM2" 'NR==NUM{ print; exit }' ${FILE} |awk -F " " '{print $16}' )
    #echo "Final power: " ${power_final}
    #echo "Convergence check power: " ${power_convergecheck}
    
    convergence_check2=$( awk -v p_final=${power_final} -v p_converge=${power_convergecheck} 'BEGIN {printf "%.4f", 100*((p_final-p_converge)/p_converge) }' )
    echo "Convergence power delta (%): " ${convergence_check2}
    if [[ "${convergence_check2}" > "${tolerance}" ]]; then
		convergence_flag="FALSE"
		echo "Rotor " ${rotor_tracker} "power convergence failed." 
    fi
      
    ((LINENUM=${LINENUM}+1 ))
    ((LINENUM2=${LINENUM2}+1 ))
    ((rotor_tracker=${rotor_tracker}+1 ))
    if [[ "${rotor_tracker}" -gt N_Rotors ]]; then
      ConvergenceRUNFLAG="FALSE"
    fi
    
done

}

################################################################################
# Function: Auto_Restart                                                       #
# Purpose: Checks the current TGRID, if not maxxed out, subs in the new TGRID, #
#           re-initializes the Solver_Inputs, and re-starts the case.          #
# .Tgrid may need adjusting with new RotCFD models being used.     			   #
################################################################################

function Auto_Restart {

	#TGRID has already been iterated if it's made it into this function.  So, grab the new TGRID file that corresponds to current ACTIVEJOB's TGRID.  i.e. TGRID[$i]
	echo "Running Auto_Restart function for ${ACTIVEJOB[$i]}." 
	# change directory into the Solver_Input folder within the ACTIVEJOB[$i] directory 
	cd ${ROTCFD_JOB_PATH}/${ACTIVEJOB[$i]}/Solver_Input
	#New strategy:  Just overwrite the flags in existing .SlvrMain to enable re-start. 
	#rm CoAxial_Batch.SlvrMain
	#cp "${ROTCFD_JOB_PATH}"/CoAxial_Batch.SlvrMain CoAxial_Batch.SlvrMain						# This places the SlvrMain with RESTART flag enabled into the working folder. 
	
	
	if [[ "${COMPRESSIBILITY_FLAG}" == "TRUE" ]] ; then
	    # Re-set the time grid and set the new iteration count. 
	    TGRID_TRACKER[$i]=0
	    rm CoAxial_Batch.Tgrid
	    cp "${ROTCFD_JOB_PATH}"/CoAxial_Batch_0-5s.Tgrid CoAxial_Batch.Tgrid
	    sed -i "s/${BASEDIR_ITERATION}/${ITERATION_GRID[$NewITERATION_GRID]}/g" CoAxial_Batch.Tgrid
	    # Edits existing SlvrMain to flag for re-start. 
	    sed -i "s/LDATPRV   = .TRUE./LDATPRV   = .FALSE./g" CoAxial_Batch.SlvrMain
	    sed -i "s/LDatTurb  = .TRUE./LDatTurb  = .FALSE./g" CoAxial_Batch.SlvrMain
	    echo "Iteration count successfully updated." 
	else
	    #Now swapping out original Tgrid for new one, based on value of TGRID[$i]
	    rm CoAxial_Batch.Tgrid
	    TGRID_INDEX=${TGRID_TRACKER[$i]}
	    cp "${ROTCFD_JOB_PATH}"/CoAxial_Batch_"${TGRID[$TGRID_INDEX]}"s.Tgrid CoAxial_Batch.Tgrid
	    echo "Time grid successfully updated to ${TGRID[$TGRID_INDEX]}s."
	    sed -i "s/${BASEDIR_ITERATION}/${ITERATION_GRID[$OldITERATION_GRID]}/g" CoAxial_Batch.Tgrid
	    # Edits existing SlvrMain to flag for re-start. 
	    sed -i "s/LDATPRV   = .FALSE./LDATPRV   = .TRUE./g" CoAxial_Batch.SlvrMain
	    sed -i "s/LDatTurb  = .FALSE./LDatTurb  = .TRUE./g" CoAxial_Batch.SlvrMain
	    echo "Iteration count successfully matched at ${ITERATION_GRID[$OldITERATION_GRID]} timesteps." 
	fi
	
	#echo "Restart" "${ACTIVEJOB[$i]}"
	# change directory into case folder, to run RotCFD 
	cd ${ROTCFD_JOB_PATH}/${ACTIVEJOB[$i]}
	#Run job (wait command will wait until previous operating completes before executing the next line of code)
	nohup /opt/RotCFD/RotCFD_K06/bin/RotUNS_Extractor --ModelName=CoAxial_Batch --nThreads=72 >/dev/null 2>&1
	nohup /opt/RotCFD/RotCFD_K06/bin/RotUNS_PreCalc --ModelName=CoAxial_Batch --nThreads=72 >/dev/null 2>&1
	nohup /opt/RotCFD/RotCFD_K06/bin/RotUNS_RotorProg --ModelName=CoAxial_Batch --nThreads=72 >/dev/null 2>&1
	nohup "${ROTCFD_BIN_PATH}"/RotUNS_Solver-ocl --ModelName=CoAxial_Batch --nThreads=72 --DeviceID=${TempDeviceID} >/dev/null 2>&1 &
	sleep "30"
	
	while [[ $(($(date +%s) - $(date -r ${ROTCFD_JOB_PATH}/${ACTIVEJOB[$i]}/${ACTIVE_FILE} +%s))) -gt "${TIMER2}" ]]; do
		  echo "Re-starting case: ${ACTIVEJOB[$i]}"
		  sleep "30"
	done 
	echo "${ACTIVEJOB[$i]} successfully re-started." 
	
	if [[ "${COMPRESSIBILITY_FLAG}" == "FALSE" ]] ; then
	    mv ${ROTCFD_JOB_PATH}/${ACTIVEJOB[$i]}/${RESTART_FILE} ${ROTCFD_JOB_PATH}/${ACTIVEJOB[$i]}/Restarts/Restart_History/							# I think we need to remove this file for the Restart check logic to not break. 
		echo "Case re-started, restart file moved to Restart_History."
	fi
}


###################################################################################
# Function: Mid_Run_Restart                                                       #
# Purpose: Re-initializes a case that was killed with TERMINATE_HARD or abrupt    #
#  			script closure (queue time elapsed).                                  #
# Ensure TGRID and TGRID Layers are properly defined above for this to work. 	  #
###################################################################################

function Mid_Run_Restart {

	echo "Running Mid_Run_Restart function for ${DIR_NAME}." 
	# change directory into the Solver_Input folder within the directory 
	cd ${ROTCFD_JOB_PATH}/${DIR_NAME}/Solver_Input
		
	# Determine which GPU has a slot open and set the appropriate TemDeviceID. 
	for p in ${deviceIDs[*]}; do 
		GPU_count=$( pgrep -f -c ${p} )
		if [[ "${GPU_count}" -lt "${NOSJ1}" ]]; then
			TempDeviceID=${p}
			echo -e "Setting TempDeviceID=${TempDeviceID} for ${DIR_NAME}."
			break;
		fi
	done
	
	# Pull TGRID value from existing /Solver_Input/CoAxial_Batch.Tgrid. Assign it to TGRID_TRACKER
	Temp_TGRID_TRACKER=$( sed -n '2p' CoAxial_Batch.Tgrid)
	Temp_TGRID_LAYERS=$( echo ${TGRID_LAYERS[@]/${Temp_TGRID_TRACKER}//} | cut -d/ -f1 | wc -w | tr -d ' ' )
	TGRID_TRACKER=( ${TGRID_TRACKER[@]} ${Temp_TGRID_LAYERS} )		
	echo "TGRID_TRACKER set to ${Temp_TGRID_LAYERS}."
	
	# Assiging TempDeviceID to DEVICE_ID_TRACKER
	DEVICE_ID_TRACKER=( "${DEVICE_ID_TRACKER[@]}" "${TempDeviceID}" )
	echo "DEVICE_ID_TRACKER set to ${TempDeviceID}."
	
	# Pull ITERATION_GRID value from existing /Solver_Input/CoAxial_Batch.Tgrid. Assign it to ITERATION_GRID_TRACKER
	Temp_ITERATION_GRID_TRACKER=$( sed -n '4p' CoAxial_Batch.Tgrid |awk '{ print $3 }' )
	Temp_ITERATION_GRID=$( echo ${ITERATION_GRID[@]/${Temp_ITERATION_GRID_TRACKER}//} | cut -d/ -f1 | wc -w | tr -d ' ' )
	ITERATION_GRID_TRACKER=( ${ITERATION_GRID_TRACKER[@]} ${Temp_ITERATION_GRID} )							#Starting ITERATION_GRID_TRACKER at first value (0-indexed). 
	echo "ITERATION_GRID_TRACKER set to ${Temp_ITERATION_GRID}."

	
	# Edits existing SlvrMain to flag for re-start.  These should already be TRUE. 
	sed -i "s/LDATPRV   = .FALSE./LDATPRV   = .TRUE./g" CoAxial_Batch.SlvrMain
	sed -i "s/LDatTurb  = .FALSE./LDatTurb  = .TRUE./g" CoAxial_Batch.SlvrMain
	
	# change directory into case folder, to run RotCFD 
	cd ${ROTCFD_JOB_PATH}/${DIR_NAME}
	#Run job (wait command will wait until previous operating completes before executing the next line of code)
	nohup /opt/RotCFD/RotCFD_K06/bin/RotUNS_Extractor --ModelName=CoAxial_Batch --nThreads=72 >/dev/null 2>&1
	nohup /opt/RotCFD/RotCFD_K06/bin/RotUNS_PreCalc --ModelName=CoAxial_Batch --nThreads=72 >/dev/null 2>&1
	nohup /opt/RotCFD/RotCFD_K06/bin/RotUNS_RotorProg --ModelName=CoAxial_Batch --nThreads=72 >/dev/null 2>&1
	nohup "${ROTCFD_BIN_PATH}"/RotUNS_Solver-ocl --ModelName=CoAxial_Batch --nThreads=72 --DeviceID=${TempDeviceID} >/dev/null 2>&1 &
	sleep "30"
	
	while [[ $(($(date +%s) - $(date -r ${ROTCFD_JOB_PATH}/${ACTIVEJOB[$i]}/${ACTIVE_FILE} +%s))) -gt "${TIMER2}" ]]; do
		  echo "Re-starting case: ${DIR_NAME}"
		  sleep "30"
	done 
	echo "${DIR_NAME} successfully re-started." 
	
	rm ${ROTCFD_JOB_PATH}/${DIR_NAME}/${RESTART_FILE} 							# I think we need to remove this file for the Restart check logic to not break. 
	echo "Case re-started, restart file removed."
	
}


#####################################################################
# Function: CLEAN_IT_UP                                             #
# Purpose: Cleans up the generated files from a run.                #
# Can either make CLEANUP=FALSE if you want to turn off both, or    #
# 	can comment out one or the other below if desired. 				#
# On NAS, space not a concern. Keep files. -> CLEANUP==FALSE. 		#
#####################################################################

function CLEAN_IT_UP {

local -r CLEAN_JOB=$1	
echo "Cleaning Directory: ${ACTIVEJOB[$i]}."

# Grid_Output deleted- can keep one set in the BASEDIR, and then copy back into any cleaned simulation directory to again enable plotting the saved simulation data. 
# Deleted because every single case has the same duplicate (very large) Grid_Output folder. 
# If disk space is really not a concern, can change CLEANUP to FALSE in above variable declarations. 
rm ${ROTCFD_JOB_PATH}/${ACTIVEJOB[$i]}/${GRID_OUTPUT}/*
# Delete the restart file 
# This is unique to each case.  Only delete if trying to conserve space and don't plan to later run the cases longer. File is very large. 
# If disk space is of no concern, can change CLEANUP to FALSE in above variable declarations. 
rm ${ROTCFD_JOB_PATH}/${ACTIVEJOB[$i]}/${RESTART_FILE}

}


###################################################################
# Function: ITERATE                                               #
# Purpose: Iterates through the parametrized matrix.              #
# Should not need any modification. 							  #
###################################################################


function ITERATE {

	#Check what values we should iterate or is task complete. Order: RPM, V_MAG, SA_DEG.
	if [[ "${R}" -ne "${RPM_SIZE}" ]]; then
		let "R++"
	elif [[ "${V}" -ne "${V_SIZE}" ]]; then
		let "V++"
		R=0
	elif [[ "${S}" -ne "${SA_SIZE}" ]]; then
		let "S++"
		R=0
		V=0
	else 
		NEWCASERUNFLAG="FALSE"										#If i,j, and k, all at their SIZEs, then no more tasks to run.
	fi
	
	# Iterative Halt for partial runs.	
	if [[ "${S}" -eq "${SA_ITHALT}" ]]; then
		NEWCASERUNFLAG="FALSE"
	fi
	if [[ "${V}" -eq "${V_ITHALT}" ]]; then
		NEWCASERUNFLAG="FALSE"
	fi
	if [[ "${R}" -eq "${RPM_ITHALT}" ]]; then
		NEWCASERUNFLAG="FALSE"
	fi

}


####################################################################
# Main Code.  This is the while loop that iterates all cases.      #
####################################################################

cd ${ROTCFD_JOB_PATH}
#rm -r Coax_BSTAR_SA* 										#Uncomment this line to delete all simulation folders at start of each run in RotCFD_Job_Path when testing/debugging. 

while [[ "${RUNFLAG}" == "TRUE" ]]; do						# While RUNFLAG is TRUE, continue executing script.
# Kills script if one of the two TERMINATE files are found. 
#  To activate one, create a file 'TERMINATE_SOFT' or 'TERMINATE_HARD' (no file extension name) in the directory containing this script where qsub submitted it from.
#  Currently, if multiple scripts running in same directory... it will do the below to all active scripts.  
#  BE SURE TO REMOVE THE TERMINATE FILE BEFORE STARTING A NEW SCRIPT, OR IT WILL TERMINATE IMMEDIATELY.  
# TERMINATE_SOFT switches the newcaserunflag so no new jobs are started, but it allows running jobs to finish. 
# TERMINATE_HARD kills the script and all child processes, and closes the node. 
   [[ -f ${PBS_O_WORKDIR}/TERMINATE_SOFT ]] && { NEWCASERUNFLAG="FALSE"; }
   [[ -f ${PBS_O_WORKDIR}/TERMINATE_HARD ]] && { break; }

TASKS=$( ps -A |grep -c RotUNS_Solver-o )				# We will allow a maximum of NOSJ solvers to be running at once.  Only reads properly on this particular setup if you shorten the name to "RotUNS_Solver-o"
														# That might or might not be unique to all RotCFD usage on Linux machines.  Seems to work still on NAS. 
ACTIVE_ARRAY_SIZE="${#ACTIVEJOB[@]}"
#echo "${ACTIVE_ARRAY_SIZE}"
if [[ "${ACTIVE_ARRAY_SIZE}" -lt "${NOSJ}" && "${NEWCASERUNFLAG}" == "TRUE" ]]; then
	
	tempSA=${SA_DEG[$S]}
	tempV_MAG=${V_MAG[$V]}
	tempRPM=${RPM[$R]}
	
	DIR_NAME=${CPBASEDIR}_SA${tempSA}_Vmag${tempV_MAG}_RPM${tempRPM}
	let "ITERATION++"
	
	# Check if this flight condition (DIR_NAME) was already successfully completed. 
	if [[ -f "${CP_PATH}/${DIR_NAME}/${ACTIVE_FILE}" ]]; then  
		# Calling the function ITERATE to iterate to next flight condition in the parametrized matrix.
		echo -e "\n${DIR_NAME} already completed. Iterating." 
		ITERATE	
		continue
	fi
	
	# Check if this flight condition (DIR_NAME) was already started but not yet finished. 
	# Most likely the queue time was exceeded, or the script was terminated with TERMINATE_HARD. 
	# In this case, need to re-set the job tracker variables to properly jump back into the script. 
	if [[ -f "${ROTCFD_JOB_PATH}/${DIR_NAME}/${ACTIVE_FILE}" ]]; then  
	    # The directory exists.  Now check for a re-start file. 
		echo -e "\n${DIR_NAME} was started but never finished. Checking for re-start file." 
		if [[ -f "${ROTCFD_JOB_PATH}/${DIR_NAME}/${RESTART_FILE_MID_RUN}" ]]; then  
			echo "Re-start file exists for ${DIR_NAME}. Copying newest re-start file one directory up." 
			#Temp_Restart_File=$(find Restarts/Restart_History/. -type f -exec stat -c '%Y %n' {} \; | sort -nr | awk 'NR==1,NR==1 {print $2}' )
			cp "${ROTCFD_JOB_PATH}/${DIR_NAME}/${RESTART_FILE_MID_RUN}" "${ROTCFD_JOB_PATH}/${DIR_NAME}/Restarts/"
			if [[ -f "${ROTCFD_JOB_PATH}/${DIR_NAME}/${RESTART_FILE}" ]]; then  
				echo "Re-start file for ${DIR_NAME} succesfully moved, calling Mid_Run_Restart."
			fi
			# Add the case to the Running Job Array, appending. 
			ACTIVEJOB=( "${ACTIVEJOB[@]}" "${DIR_NAME}" )
		
			Mid_Run_Restart
			ITERATE	
			continue  # Need this to exit rest of commands.. Just re-start case then move to next condition.
		else
			echo "${DIR_NAME} was started but no re-start file exists.  Deleting folder and re-starting case." 
			rm -r "${ROTCFD_JOB_PATH}/${DIR_NAME}"
		fi  # if [[ -f "${ROTCFD_JOB_PATH}/${DIR_NAME}/${RESTART_FILE_MID_RUN}" ]]; Checking for re-start. 
	fi  #if [[ -f "${ROTCFD_JOB_PATH}/${DIR_NAME}/${ACTIVE_FILE}" ]]; Checking for re-start. 
	
	# Determine which GPU has a slot open and set the appropriate TemDeviceID. 
	for p in ${deviceIDs[*]}; do 
		GPU_count=$( pgrep -f -c ${p} )
		if [[ "${GPU_count}" -lt "${NOSJ1}" ]]; then
			TempDeviceID=${p}
			echo -e "\n Setting TempDeviceID=${TempDeviceID} for ${DIR_NAME}."
			break;
		fi
	done

	# Update Running Job Array, appending. 
	ACTIVEJOB=( "${ACTIVEJOB[@]}" "${DIR_NAME}" )
	# Updated running TGRID tracker array, appending. This sets the same row of TGRID_TRACKER to hold the initial value of TGRID. Will later be iterated on restart if needed. 
	TGRID_TRACKER=( ${TGRID_TRACKER[@]} 0 )												#Starting TGRID_TRACKER at first value (0-indexed). 
	DEVICE_ID_TRACKER=( "${DEVICE_ID_TRACKER[@]}" "${TempDeviceID}" )
	ITERATION_GRID_TRACKER=( ${ITERATION_GRID_TRACKER[@]} 0 )							#Starting ITERATION_GRID_TRACKER at first value (0-indexed). 

	
	# Tip Speed=(RPM/60)*2*pi*0.675. pi=atan2(0, -1). Keep it to 4 decimal places. Pad zeros to 6, because file (confusingly) wants this.
        TSPEED=$( awk -v TRPM=${tempRPM} 'BEGIN {printf "%.4f", (TRPM/60)*2*(atan2(0, -1))*0.675}' )
        TSPEED=${TSPEED}00
        
        # SA_Radians=SA_DEG*(pi/180). pi=atan2(0, -1). Keep it to 4 decimal places. Pad zeros to 6, because file (confusingly) wants this.
        SA_Radians=$( awk -v TSA=${tempSA} 'BEGIN {printf "%.6f", TSA*((atan2(0, -1))/180)}' )

	# make sure we are in the correct folder. i.e. Where you want all the different RotCFD directories stored. 
	cd ${ROTCFD_JOB_PATH}
	# copies the basefile and renames it based on i, j, and k
	cp -r ${BASEDIR}/. ${DIR_NAME}/
	echo -e " \n${DIR_NAME}"
	# change directory into the Solver_Input folder within the new case we just created
	cd ${ROTCFD_JOB_PATH}/${CPBASEDIR}_SA${tempSA}_Vmag${tempV_MAG}_RPM${tempRPM}/Solver_Input
	
	# change directory into the Solver_Input folder within the new case we just created
	#cd ${ROTCFD_JOB_PATH}/${CPBASEDIR}_SA${tempSA}_Vmag${tempV_MAG}_RPM${tempRPM}/Solver_Input
	cd ${ROTCFD_JOB_PATH}/${DIR_NAME}/Solver_Input	

	# calculates the x and y velocities we need based on tempSA and tempV_MAG.
	X_VEL=$( awk -v VMAG=${tempV_MAG} -v SA=${SA_Radians} 'BEGIN {printf "%.4F", VMAG*cos(SA)}' ) # !!  must have 4 decimal places, padded to 6 with 0's
	X_VEL=${X_VEL}00
	# echo "X_VEL is equal to ${X_VEL}"
	Y_VEL=$( awk -v VMAG=${tempV_MAG} -v SA=${SA_Radians} 'BEGIN {printf "%.4F", VMAG*sin(SA)}' ) # !!  must have 4 decimal places, padded to 6 with 0's
	Y_VEL=${Y_VEL}00
	# echo "Y_VEL is equal to ${Y_VEL}"
	
	# overwrites the tempRPM into relevant locations
	sed -i "s/77.177700/${TSPEED}/g" CoAxial_Batch.SlvrRot 
	# overwrites the X_VEL into relevant location of SlvrMain
	sed -i "s/7.177700/${X_VEL}/g" CoAxial_Batch.SlvrMain
	# overwrites the Y_VEL into relevant location of SlvrMain
	sed -i "s/6.177700/${Y_VEL}/g" CoAxial_Batch.SlvrMain
	# Set the file location within Solver main to place and look for the restart files
	sed -i "s/DIR_NAME/${DIR_NAME}/g" CoAxial_Batch.SlvrMain
	# Set the time grid to the first value in ITERATION_GRID
	sed -i "s/${BASEDIR_ITERATION}/${ITERATION_GRID[0]}/g" CoAxial_Batch.Tgrid
	
	# All cases will first run the above times, then check convergence. If convergence failed, then go to 2nd value (e.g. 1s), 3rd value (2s), final value (3s). 
	# Similar as above line for iteration count.  

	# There are five different BndCnd.dat file formats depending on which tempSA value we are preparing to run, then a few numbers to overwrite. 
	# 5 cases for a 2D sweep of velocities.  i.e. No side-slip.  Side-slip would expand to many possible combinations (15 or more?). 
	# This could be scripted better, but to avoid a likely error in messing with the text file formatting, easier to just overwrite the correct format then sub(sed) the numbers.

		# Axial_Climb.dat for temp_SA = -90
		if [[ ${S} -eq 0 ]]; then
		  rm BndCnd.dat
		  cp "${ROTCFD_JOB_PATH}"/BndCnd_Axial-Climb.dat BndCnd.dat

		# Axial_Descent.dat for temp_SA = 90
		elif [[ ${S} -eq 13 ]]; then
		  rm BndCnd.dat
		  cp "${ROTCFD_JOB_PATH}"/BndCnd_Axial-Descent.dat BndCnd.dat
		  
		# Edge-Wise.dat for temp_SA = 0
		elif [[ ${S} -eq 6 ]]; then
		  rm BndCnd.dat
		  cp "${ROTCFD_JOB_PATH}"/BndCnd_Edge-Wise.dat BndCnd.dat
		  
		# Climb.dat if temp_SA -gt -90 && -lt 0
		elif [[ ${S} -gt 0 && ${S} -lt 6 ]]; then
		  rm BndCnd.dat
		  cp "${ROTCFD_JOB_PATH}"/BndCnd_Climb.dat BndCnd.dat
		  
		# Descent.dat if temp_SA -gt 0 && -lt 90
		elif [[ ${S} -gt 6 && ${S} -lt 13 ]]; then
		  rm BndCnd.dat
		  cp "${ROTCFD_JOB_PATH}"/BndCnd_Descent.dat BndCnd.dat
	
		# These are the only possible options based on current 2D velocity inflow... but throw a flag in case none of these stick...
		else NEWCASERUNFLAG="FALSE"    # Panic="TRUE"
			echo "Not properly matched with a BndCnd.dat file. Check case: ${ACTIVEJOB[$i]}"
			echo "Not properly matched with a BndCnd.dat file. Check case: ${ACTIVEJOB[$i]}" >> ${ERROR_LOG}
		fi
		
	# substitutes the proper values of X_VEL and Y_VEL into the appropriate locations in the newly copied BndCnd.dat file
	sed -i "s/7.177700/${X_VEL}/g" BndCnd.dat
	sed -i "s/6.177700/${Y_VEL}/g" BndCnd.dat
	
	# change directory into case folder, to run RotCFD 
	cd ${ROTCFD_JOB_PATH}/${DIR_NAME}	
		
	#Run job (wait command will wait until previous operating completes before executing the next line of code)
	nohup "${ROTCFD_BIN_PATH}"/RotUNS_Extractor --ModelName=CoAxial_Batch --nThreads=72 >/dev/null 2>&1
	nohup "${ROTCFD_BIN_PATH}"/RotUNS_PreCalc --ModelName=CoAxial_Batch --nThreads=72 >/dev/null 2>&1
	nohup "${ROTCFD_BIN_PATH}"/RotUNS_RotorProg --ModelName=CoAxial_Batch --nThreads=72 >/dev/null 2>&1
	nohup "${ROTCFD_BIN_PATH}"/RotUNS_Solver-ocl --ModelName=CoAxial_Batch --nThreads=72 --DeviceID=${TempDeviceID} >/dev/null 2>&1 &
	sleep "20"
	
	# Calling the function ITERATE to iterate through the parametrized matrix, check for job completion. 
	ITERATE
	
else
	#echo "Max cases running."									#Used this to write to terminal when max # cases were running, but it was too much output every 60s.
	sleep "${TIMER}"											#If NOSJ already running, sleep and try again.


	# Iterate over ActiveJob array, checking for completed or hung tasks.
	for i in ${!ACTIVEJOB[@]}; do
	
		  TempDeviceID=${DEVICE_ID_TRACKER[$i]}
		  COMPRESSIBILITY_FLAG="FALSE"								#Re-setting Boolean flag to determine if compressibility was detected. 
		  OldITERATION_GRID=${ITERATION_GRID_TRACKER[$i]}

		  #Check first for compressibility in each running case.  If it's there, re-start with higher iteration count
		  cd ${ROTCFD_JOB_PATH}/${ACTIVEJOB[$i]}/Process_Output/
		  #echo "Entered directory " "$PWD"
		  TempGREP=$(grep -cim1 "Compressibility" Solver.out)

		   if [[ "${TempGREP}" -gt "0" ]]; then
		     TempGREPlineNUM=$(grep -nm1 "Compressibility" Solver.out)
		     if [[ "${TempGREPlineNUM}" -eq "69" ]]; then 								# If the compressibility is automatically switched, force compressibility off and re-start. 
		         echo "This case needs to be restarted with compressibility turned off." 
		     fi
		     echo -e "     \nCompressible CFL issue found." 
		     kill -9 $( ps -elfyc e |grep ${ACTIVEJOB[$i]} |grep -v grep |grep -v sleep |awk -F " " '//{print $3}' )
		     sleep "10"
		     COMPRESSIBILITY_FLAG="TRUE"
		     if [[ ${OldITERATION_GRID} -lt ${ITERATION_GRID_SIZE} ]]; then
		       ((NewITERATION_GRID=${OldITERATION_GRID}+1 ))
		       ITERATION_GRID_TRACKER[$i]=${NewITERATION_GRID}
		       echo "Increased iteration count and re-starting job ${ACTIVEJOB[$i]}."
		       Auto_Restart
		       #Continue is to keep the script from cleaning and un-setting this one, since it was just re-started. 
		       continue 										#Case was re-started, move to the next row of ACTIVEJOB and continue checking each one for completion. 
		     else		      
		       echo "Job " "${ACTIVEJOB[$i]}" " failed CFL_check at the maximum allowed iteration count. Review the case." 
		       echo "Job " "${ACTIVEJOB[$i]}" " failed CFL_check at the maximum allowed iteration count. Review the case." >> ${ERROR_LOG}
		       unset ACTIVEJOB[$i]
		       unset TGRID_TRACKER[$i]
		       unset DEVICE_ID_TRACKER[$i]
		       unset ITERATION_GRID_TRACKER[$i]
		       continue
		     fi # if [[ ${OldITERATION_GRID} -lt ${ITERATION_GRID_SIZE} ]]; (checks if a finer timestep, dt, is available to try)
		   #else   echo "     No compressibility issues detected."
		  
		   fi # if [[ "${TempGREP}" -gt "0" ]];

		#Check if final Restart File is present (indication job has completed)
		if [[ -f "${ROTCFD_JOB_PATH}/${ACTIVEJOB[$i]}/${RESTART_FILE}" ]]; then  
		   # If Restart File is present, initial run complete. Check for convergence on all rotor thrust and power. This is 2*N_Rotors parameters to check. 
		   # Thrust_Rotor1 = 4th numeric value from left. Power_Rotor1 = 16th numeric value from left. Using awk syntax: awk -F " " '{print $4}' and awk -F " " '{print $16}' respectively. 
		  
		  #Call Convergence_check function 
		  echo -e "     \nChecking for convergence of case ${ACTIVEJOB[$i]}."		  
		  Convergence_Check 
		 
		  # If the convergence flag was tripped (failed) then put in next higher TGrid file and restart the run. 
		  if [[ ${convergence_flag} == "FALSE" ]]; then
		  echo "Convergence check failed for job ${ACTIVEJOB[$i]}."

		    #Check TGRID status.  
		    TempTGRID=${TGRID_TRACKER[$i]}
		    if [[ ${TempTGRID} -lt ${TGRID_SIZE} ]]; then
		      ((TempTGRID=${TempTGRID}+1 ))
		      TGRID_TRACKER[$i]=${TempTGRID}
		      
		      echo "Increased runtime and re-starting job ${ACTIVEJOB[$i]}."
		      Auto_Restart
		      #Continue is to keep the script from cleaning and un-setting this one, since it was just re-started. 
		      continue 		#Case was re-started, move to the next row of ACTIVEJOB and continue checking each one for completion. 
		    
		    else 
		      echo "Job " "${ACTIVEJOB[$i]}" " failed rotor convergence check at the maximum allowed time. Review the case." 
		      echo "Job " "${ACTIVEJOB[$i]}" " failed rotor convergence check at the maximum allowed time. Review the case." >> ${ERROR_LOG}

		      #Clean it up?
		    #  if [[ "${CLEANUP}" == "TRUE" ]]; then
			#	CLEAN_IT_UP "${ACTIVEJOB[$i]}"
		    #  fi
			#  
			#  #Move to storage directory if desired (CPBIT Flag == TRUE).
			#  if [[ "${CPBIT}" == "TRUE" ]]; then
			#	mv -u ${ROTCFD_JOB_PATH}/${ACTIVEJOB[$i]} /${CP_PATH}
			#  fi
			  
		      unset ACTIVEJOB[$i]
		      unset TGRID_TRACKER[$i]
		      unset DEVICE_ID_TRACKER[$i]
		      unset ITERATION_GRID_TRACKER[$i]
		      continue
		    fi
		  
		  fi # if [[ ${convergence_flag} == "FALSE" ]]
		    
		
		elif [[ $(($(date +%s) - $(date -r ${ROTCFD_JOB_PATH}/${ACTIVEJOB[$i]}/${ACTIVE_FILE} +%s))) -lt "${JOBTIMER}" ]]; then
		  #echo "Still running case: ${ACTIVEJOB[$i]}"
		  continue
		  
		# If current activejob doesn't have a restart file yet, check if job has hung.
		# Equation for modification time comparison: $(($(date +%s) - $(date -r file.txt +%s))) 
		elif [[ $(($(date +%s) - $(date -r ${ROTCFD_JOB_PATH}/${ACTIVEJOB[$i]}/${ACTIVE_FILE} +%s))) -gt "${JOBTIMER}" ]]; then
		   #Kill the related process. "ps -elfyc e |grep case_name |grep -v grep |grep -v sleep" (and parse for process ID, 3rd column value)
		   # Typically if the job is hung, there is no process running... so the above command will throw a flag/ error to the effect 'no process running'. That's OK. 
		   kill -9 $( ps -elfyc e |grep ${ACTIVEJOB[$i]} |grep -v grep |grep -v sleep |awk -F " " '//{print $3}' )
		   sleep "10"
		   #Write Error to log file.
		   echo "Case ${ACTIVEJOB[$i]} seems to have hung up." >> ${ERROR_LOG}
		   echo "Case ${ACTIVEJOB[$i]} seems to have hung up." 
		   
		   unset ACTIVEJOB[$i]
		   unset TGRID_TRACKER[$i]
		   unset DEVICE_ID_TRACKER[$i]
		   unset ITERATION_GRID_TRACKER[$i]
		   continue
		fi
		   		
		
		#Clean it up?
		if [[ "${CLEANUP}" == "TRUE" ]]; then
		   CLEAN_IT_UP "${ACTIVEJOB[$i]}"
		fi
		#Move to storage directory if desired (CPBIT Flag == TRUE).
		if [[ "${CPBIT}" == "TRUE" ]]; then
			mv -u ${ROTCFD_JOB_PATH}/${ACTIVEJOB[$i]} /${CP_PATH}
		fi
		
		# Cleaning tasks done. Clear array values.
		echo "Case ${ACTIVEJOB[$i]} completed."
		unset ACTIVEJOB[$i]
		unset TGRID_TRACKER[$i]
		unset DEVICE_ID_TRACKER[$i]
		unset ITERATION_GRID_TRACKER[$i]
                
  
	done # for i in ${!ACTIVEJOB[@]}
	
    ACTIVE_ARRAY_SIZE="${#ACTIVEJOB[@]}"
    if [[ ${ACTIVE_ARRAY_SIZE} -lt 1 ]]; then
		RUNFLAG="FALSE"
	fi

fi  # if [[ "${ACTIVE_ARRAY_SIZE}" -lt "${NOSJ}" && "${NEWCASERUNFLAG}" == "TRUE" ]];  (convergence check loop)


done  # main script while loop 

echo "RotCFD_AUTOJOB completed. Congratulations." 

} > "${INFOFILE2}"