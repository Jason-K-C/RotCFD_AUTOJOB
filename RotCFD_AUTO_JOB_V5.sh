#!/bin/bash
#######################################################################################
# Hybrid BEMT-URANS RotCFD Automated GPU parallelization and processing script.       #
# Written by Jason Cornelius and Kirk Heller at The Pennsylvania State University.    #
# Features:  Auto job creation, concurrent parallelization across multiple GPUs,      #
# automated solver parameter tuning, convergence check, clean-up. 					  # 
# December 2022                                                                       #
#######################################################################################

#######################################################################################
# Variable Declarations and Run Parameters. 
# Check Matrix Arrays:  SA_DEG, V_MAG, and RPM arrays.
# Check Run Parameters: N_Rotors, ITHALT values, NOSJ. 
# Check Flags: RestartFLAG, CLEANUP, and CPBIT. 
# Check Directories: RotCFD_JOB_PATH, RotCFD 'bin' path, BASEDIR, CPBASEDIR, CP_PATH.   #These may change depending on where the orgiinal RotCFD files are located, or where you want to copy them to. 

# Matrix Arrays
SA_DEG=(-90 -75 -60 -45 -30 -15 -5 0 5 15 30 45 60 75 90)		#Shaft angle SA Array in Degrees. (15)
V_MAG=(5 10 15 20 25 30 35) 									#Velocity Magnitude Array. (7)
RPM=(200 400 600 800 1000 1200)									#RPM Array. (6)
TGRID=(0 1 2 3)													#TGRID array, for telling the script how long to run (physical simulation time, not wall-clock). 
# Iteration grid for new matrix 
ITERATION_GRID=(2000 3000 4000 5000)							#ITERATION_GRID holds the number of iterations that will be cycled through each layer of the RotCFD .Tgrid input file. It starts low and increases as needed for divergence due to compressibiilty. 

# Run Parameters
declare -i N_Rotors=2											#Number of rotors in RotCFD model. Used for checking convergence. 
declare -i SA_ITHALT=9											#Position in SA array to halt tasks (for partial runs). Full run is final position in SA Array +1 (0-indexed).
declare -i V_ITHALT=-1											#Position in V array to halt tasks (for testing purposes, default is a negative # so as to not be triggered.
declare -i RPM_ITHALT=-1										#Position in RPM array to halt tasks (for testing purposes, default is a negative # so as to not be triggered.
declare -i DeviceID1=65536										#DeviceID for the RTX 3060.  Must identify this # for each new machine the script is used on. Run a job, this number can be found in the Linux NVTOP command output. 
declare -i DeviceID2=2162688									#DeviceID for the RTX 3080-ti.  Same note as above. 
declare -i DeviceID3=4980736									#DeviceID for the GTX 970.  Same note as above. 
declare -i NOSJ1=6												#Variable instructing Number of Simultaneous Jobs we allow to run on GPU1, NVIDIA RTX 3090
declare -i NOSJ2=6												#Variable instructing Number of Simultaneous Jobs we allow to run on GPU2, NVIDIA RTX 3090
declare -i NOSJ3=3												#Variable instructing Number of Simultaneous Jobs we allow to run on GPU3, NVIDIA GTX 970. 
declare -i BASEDIR_ITERATION=2500								#This specifies the number used in each layer of .Tgrid within the basefolder.  Changes depending on RotCFD model. 

# Flags
RestartFLAG="FALSE"												#This flag is for manual re-starting of completed runs. TRUE for restarting. The script function 'Convergence_Check' will auto-restart a run if it didn't converge to within tolerance.
CLEANUP="TRUE"													#Variable to enable or disable file cleanup to conserve space. (Any value other than TRUE is considered FALSE)
CPBIT="TRUE"													#Variable to enable or disable file results copying to alternate location.
	
# Directories. 
ROTCFD_JOB_PATH="/home/RotCFD/AUTOJOB"							#Path to topmost working directory containing base directory to duplicate.
ROTCFD_BIN_PATH="/opt/RotCFD/RotCFD_K06/bin/"					#Path to the RotCFD binary directory.
BASEDIR="BASEFOLDER"											#Name of base directory that will be duplicated. This is the original base RotCFD model that will be copied and modified. 
CPBASEDIR="RotorDesignA"										#Name of iterative basefile name (prefix that will be used to duplicate BASEDIR).
CP_PATH="Storage_1/Completed_Simulations/RotorDesignA/"			#Location of where results are to be copied to.  (second internal hard drive, for example). 



# Advanced Variables - Shouldn't require any modification. 
declare -i NOSJ=${NOSJ1}+${NOSJ2}+${NOSJ3}						#Variable instructing Number of Simultaneous Jobs we allow to run (8 if RotCFD GUI not open), 1 case in GUI -> NOSJ = 6.
declare -a ACTIVEJOB											#Array that holds names of current running jobs.
declare -a TGRID_TRACKER										#Array that monitors the current time grid, so the script knows which TGRID to substitute upon subsequent automated restarts.
declare -a ITERATION_GRID_TRACKER								#Array that monitors the current iteration grid, so the script knows which ITERATION_GRID to substitute upon subsequent automated restarts. 
declare -i S=0													#SA Array indexer.
declare -i V=0													#V_MAG Array indexer.
declare -i R=0													#RPM Array indexer.
declare -i SA_SIZE="${#SA_DEG[@]}-1"							#Size of SA Array -1 since 0-indexed.
declare -i V_SIZE="${#V_MAG[@]}-1"								#Size of V_MAG Array -1 since 0-indexed.
declare -i RPM_SIZE="${#RPM[@]}-1"								#Size of RPM Array -1 since 0-indexed.
declare -i TGRID_SIZE="${#TGRID[@]}-1"							#Size of TGRID Array -1 since 0-indexed. 
declare -i ITERATION_GRID_SIZE="${#ITERATION_GRID[@]}-1"		#Size of ITERATION_GRID Array -1 since 0-indexed. 
TSPEED=0														#Variable to hold Tip Speed Calculations (floating point).

NEWCASERUNFLAG="TRUE"											#Boolean flag to continue interations.
RUNFLAG="TRUE"													#Boolean flag to continue interations.
COMPRESSIBILITY_FLAG="FALSE"									#Boolean flag to determine if compressibility was detected. 
declare -i TASKS=0												#Variable to keep track of number of jobs running.

# Can modify this for de-bugging.  60s is default value. 
declare -i TIMER=60												#Time (in Seconds) to wait before checking NOSJ again.
declare -i JOBTIMER=300											#Time (in seconds) to wait before considering a job, via ACTIVE_FILE modification time, to be hung, maybe diverged (?).

ACTIVE_FILE="/Rotor_Performance/Performance/TrimLog2.out"		#Sub-directory path and file of ROTCFD_JOB_PATH directory that is being written to. This output file is what is monitored to determine job activity.
ERROR_LOG="${ROTCFD_JOB_PATH}/ERROR.log"						#Writes any errors from this script into the ERROR.log file within the main directory the cases are being run in. 
ROTCFD_JOB_PATH_RESTART="/home/joc5693/Desktop/RotCFD"			#This allows updating the re-start file.  DO NOT CHANGE. 

# Cleanup Variables. 
# *Note: Only cleanup variables after job has fully completed. 
# i.e. Check for convergence first, determine if restart is needed, etc. 
# Decided to not keep re-start files.  Can re-run a simulation if really needed for some reason.  
# .RtrGeom and Grid_Output also deleted- can keep one set in the BASEDIR, 
# and then copy back into any cleaned simulation directory to again enable plotting the saved simulation data.  

RESTART_FILE="/Restarts/CoAxial_Batch.Rst"						#Location of restart file, in subdirectory of ROTCFD_JOB_PATH directory, that may be cleaned out to conserve space.
GEOM="/Solver_Input/CoAxial_Batch.RtrGeom"						#Location of RtrGeom file, in subdirectory of ROTCFD_JOB_PATH directory, that may be cleaned out to conserve space.
GRID_OUTPUT="/Grid_Output/"										#Subdirectory ROTCFD_JOB_PATH directory containing grid geometry files that may be cleaned out to conserve space. 

declare -i ITERATION=0
DIR_NAME=""														#Internal variable to hold current directory name of running task. Don't touch this. It's here for completionist sake. Value assigned at start of iteration.

 
 
#######################################################################################
# Function: Convergence_Check
# Purpose: Checks for convergence of a specifc run in activejob array. 
# Calling: output <output level> <format> <output string>
# Returns: None.  All errors handled internally


function Convergence_Check {

local -r RESTART_JOB=$1	
#echo "Checking convergence of: ${RESTART_JOB}"

FILE=${ROTCFD_JOB_PATH}/${ACTIVEJOB[$i]}/${ACTIVE_FILE}			#Points to the TrimLog2.out file to check convergence of each rotor thrust and power. 
convergesteps=100												#Decrease this for de-bugging, set to 100 for real runs.
tolerance=0.25													#Tolerance (in percent) that anything greater than will flag a failed convergence.  Decrease this for de-bugging, set to 0.25 for real runs. 

FSIZE=$( wc -l < ${FILE} ) 										#Returns total number of lines in text file. (last blank line not counted)

((LINENUM=${FSIZE}-(3+2*${N_Rotors}) ))							#This sets LINENUM to be Rotor1 row of output (not final condensed output)

((LINENUM2=${LINENUM}-(N_Rotors*${convergesteps}) ))			#This sets LINENUM2 to be Rotor1 row of output number of 'convergesteps' back from last.  (i.e. 4000 - '100' = 3900) 

#echo "Final thrust is: " $( awk -v NUM="$LINENUM" 'NR==NUM{ print; exit }' ${FILE} |awk -F " " '{print $4}' ) #Grabs Line Number "NR==" and returns value | Break apart string based on spaces and return 4th element.
#echo "Final power is: "$( awk -v NUM="$LINENUM" 'NR==NUM{ print; exit }' ${FILE} |awk -F " " '{print $16}' )


convergence_flag="TRUE" 										#Initializing the convergence flag 
ConvergenceRUNFLAG="TRUE" 										#Initializing the convergence run flag 
declare -i rotor_tracker=1	

while [[ "${ConvergenceRUNFLAG}" == "TRUE" && "${convergence_flag}" == "TRUE" ]]; do	

    echo "Checking convergence for rotor # " ${rotor_tracker}
    thrust_final=$( awk -v NUM="$LINENUM" 'NR==NUM{ print; exit }' ${FILE} |awk -F " " '{print $4}' )
    thrust_convergecheck=$( awk -v NUM="$LINENUM2" 'NR==NUM{ print; exit }' ${FILE} |awk -F " " '{print $4}' )
    #echo "Final thrust: " ${thrust_final}
    #echo "Convergence check thrust: " ${thrust_convergecheck}
    
    convergence_check=$( awk -v t_final=${thrust_final} -v t_converge=${thrust_convergecheck} 'BEGIN {printf "%.4f", 100*((t_final - t_converge) / t_converge) }' )	# Calculates thrust convergence
    echo "Convergence thrust delta (%): " ${convergence_check}
    
    if [[ "${convergence_check}" > "${tolerance}"} ]]; then
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

#######################################################################################
# Function: Auto_Restart
# Purpose: Checks the current TGRID, if not maxxed out, subs in the new TGRID, re-initializes the Solver_Inputs, and re-starts the case. 
# Calling: output <output level> <format> <output string>
# Returns: None.  All errors handled internally

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
	    echo "Time grid successfully updated."
	    sed -i "s/${BASEDIR_ITERATION}/${ITERATION_GRID[$OldITERATION_GRID]}/g" CoAxial_Batch.Tgrid
	    # Edits existing SlvrMain to flag for re-start. 
	    sed -i "s/LDATPRV   = .FALSE./LDATPRV   = .TRUE./g" CoAxial_Batch.SlvrMain
	    sed -i "s/LDatTurb  = .FALSE./LDatTurb  = .TRUE./g" CoAxial_Batch.SlvrMain
	    echo "Iteration count successfully matched." 
	fi
	
	#echo "Restart" "${ACTIVEJOB[$i]}"
	# change directory into case folder, to run RotCFD 
	cd ${ROTCFD_JOB_PATH}/${ACTIVEJOB[$i]}
	#Run job (wait command will wait until previous operating completes before executing the next line of code)
	nohup /opt/RotCFD/RotCFD_K06/bin/RotUNS_Extractor --ModelName=CoAxial_Batch --nThreads=48 >/dev/null 2>&1
	nohup /opt/RotCFD/RotCFD_K06/bin/RotUNS_PreCalc --ModelName=CoAxial_Batch --nThreads=48 >/dev/null 2>&1
	nohup /opt/RotCFD/RotCFD_K06/bin/RotUNS_RotorProg --ModelName=CoAxial_Batch --nThreads=48 >/dev/null 2>&1
	nohup "${ROTCFD_BIN_PATH}"/RotUNS_Solver-ocl --ModelName=CoAxial_Batch --nThreads=48 --DeviceID=${TempDeviceID} >/dev/null 2>&1 &
	# nohup /opt/RotCFD/RotCFD_K06/bin/RotUNS_Solver-ocl --ModelName=CoAxial_Batch --nThreads=48 --DeviceID=65536 >/dev/null 2>&1 &
	sleep "${TIMER}"																	#Sleep long enough for re-start to start (updated from 30s to 60s due to suspected bug caused by time shorter than needed to create re-start file. 
	if [[ "${COMPRESSIBILITY_FLAG}" == "FALSE" ]] ; then
	    rm ${ROTCFD_JOB_PATH}/${ACTIVEJOB[$i]}/${RESTART_FILE} 							#This must be removed for the Restart check logic to not break. 
	fi
}

#######################################################################################
# Function: CLEAN_IT_UP
# Purpose: Cleans up the generated files from a run..
# Calling: output <output level> <format> <output string>
# Returns: None.  All errors handled internally

function CLEAN_IT_UP {

local -r CLEAN_JOB=$1	
echo "Cleaning Directory: ${ACTIVEJOB[$i]}."

# Delete all the contents of the Grid_Output directory within the completed case 
rm ${ROTCFD_JOB_PATH}/${ACTIVEJOB[$i]}/${GRID_OUTPUT}/*
# Delete the geomtry file.  Disabling this one for now, since .rtrgeom file is needed to view the flow solutions later on. 
# rm ${ROTCFD_JOB_PATH}/${CLEAN_JOB}/${GEOM}
# Delete the restart file 
rm ${ROTCFD_JOB_PATH}/${ACTIVEJOB[$i]}/${RESTART_FILE}

# Copy data or move it, if desired.
if [[ "${CPBIT}" == "TRUE" ]]; then
   mv -u ${ROTCFD_JOB_PATH}/${ACTIVEJOB[$i]} /${CP_PATH}
fi

}




#######################################################################################
# Main Code                                                                           #
#######################################################################################


cd ${ROTCFD_JOB_PATH}
#rm -r Coax_BSTAR_SA* 											#Uncomment this line to delete all simulation folders at start of each run in RotCFD_Job_Path when testing/debugging. 


while [[ "${RUNFLAG}" == "TRUE" ]]; do							# While RUNFLAG is TRUE, continue executing script.
TASKS=$( ps -A |grep -c RotUNS_Solver-o )						# We will allow a maximum of NOSJ solvers to be running at once.  Only reads properly on this particular setup if you shorten the name to "RotUNS_Solver-o"
										# That might or might not be unique to all RotCFD usage on Linux machines. 
ACTIVE_ARRAY_SIZE="${#ACTIVEJOB[@]}"
#echo "${ACTIVE_ARRAY_SIZE}"
if [[ "${ACTIVE_ARRAY_SIZE}" -lt "${NOSJ}" && "${NEWCASERUNFLAG}" == "TRUE" ]]; then
	
	# Determining how many jobs are running on each of the available GPUs. 
	GPU1_count=$( pgrep -f -c ${DeviceID1} )
	GPU2_count=$( pgrep -f -c ${DeviceID2} )
	#GPU3_count=$( pgrep -f -c ${DeviceID3} )
	
	if [[ "${GPU1_count}" -lt "${NOSJ1}" ]]; then
	  TempDeviceID=${DeviceID1}
	elif [[ "${GPU2_count}" -lt "${NOSJ2}" ]]; then
	  TempDeviceID=${DeviceID2}	
	#elif [[ "${GPU3_count}" -lt "${NOSJ3}" ]]; then
	  #TempDeviceID=${DeviceID3}
	fi
	
	
	tempSA=${SA_DEG[$S]}
	tempV_MAG=${V_MAG[$V]}
	tempRPM=${RPM[$R]}
	
	DIR_NAME=${CPBASEDIR}_SA${tempSA}_Vmag${tempV_MAG}_RPM${tempRPM}
	let "ITERATION++"

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
	if [[ "${RestartFLAG}" == "FALSE" ]]; then
	  cp -r ${BASEDIR}/. ${DIR_NAME}/
	  echo -e " \n${DIR_NAME}"
	  # change directory into the Solver_Input folder within the new case we just created
	  cd ${ROTCFD_JOB_PATH}/${CPBASEDIR}_SA${tempSA}_Vmag${tempV_MAG}_RPM${tempRPM}/Solver_Input
	fi
	
	
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
		elif [[ ${S} -eq 16 ]]; then
		  rm BndCnd.dat
		  cp "${ROTCFD_JOB_PATH}"/BndCnd_Axial-Descent.dat BndCnd.dat
		  
		# Edge-Wise.dat for temp_SA = 0
		elif [[ ${S} -eq 8 ]]; then
		  rm BndCnd.dat
		  cp "${ROTCFD_JOB_PATH}"/BndCnd_Edge-Wise.dat BndCnd.dat
		  
		# Climb.dat if temp_SA -gt -90 && -lt 0
		elif [[ ${S} -gt 0 && ${S} -lt 8 ]]; then
		  rm BndCnd.dat
		  cp "${ROTCFD_JOB_PATH}"/BndCnd_Climb.dat BndCnd.dat
		  
		# Descent.dat if temp_SA -gt 0 && -lt 90
		elif [[ ${S} -gt 8 && ${S} -lt 16 ]]; then
		  rm BndCnd.dat
		  cp "${ROTCFD_JOB_PATH}"/BndCnd_Descent.dat BndCnd.dat
	
		# These are the only possible options based on current 2D velocity inflow... but throw a flag in case none of these stick...
		else NEWCASERUNFLAG="FALSE"    # Panic="TRUE"
		fi
		
	# substitutes the proper values of X_VEL and Y_VEL into the appropriate locations in the newly copied BndCnd.dat file
	sed -i "s/7.177700/${X_VEL}/g" BndCnd.dat
	sed -i "s/6.177700/${Y_VEL}/g" BndCnd.dat
	
	# change directory into case folder, to run RotCFD 
#	cd ${ROTCFD_JOB_PATH}/${CPBASEDIR}_SA${tempSA}_Vmag${tempV_MAG}_RPM${tempRPM}
	cd ${ROTCFD_JOB_PATH}/${DIR_NAME}	
		
	#Run job (wait command will wait until previous operating completes before executing the next line of code)
	nohup "${ROTCFD_BIN_PATH}"/RotUNS_Extractor --ModelName=CoAxial_Batch --nThreads=64 >/dev/null 2>&1
	nohup "${ROTCFD_BIN_PATH}"/RotUNS_PreCalc --ModelName=CoAxial_Batch --nThreads=64 >/dev/null 2>&1
	nohup "${ROTCFD_BIN_PATH}"/RotUNS_RotorProg --ModelName=CoAxial_Batch --nThreads=64 >/dev/null 2>&1
	nohup "${ROTCFD_BIN_PATH}"/RotUNS_Solver-ocl --ModelName=CoAxial_Batch --nThreads=64 --DeviceID=${TempDeviceID} >/dev/null 2>&1 &
	sleep "5"
	
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
	
else
	#echo "Max cases running."										#Used this to write to terminal when max # cases were running, but it was too much output every 60s.
	sleep "${TIMER}"												#If NOSJ already running, sleep and try again.


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
			
		    if [[ "${TempGREPlineNUM}" -eq "69" ]]; then 			# If the compressibility is automatically switched, force compressibility off and re-start. 
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
		      continue 												#Case was re-started, move to the next row of ACTIVEJOB and continue checking each one for completion. 
		    else		      
		      echo "Job " "${ACTIVEJOB[$i]}" " failed CFL_check at the maximum allowed iteration count. Review the case." 
		      echo "Job " "${ACTIVEJOB[$i]}" " failed CFL_check at the maximum allowed iteration count. Review the case." >> ${ERROR_LOG}
		      unset ACTIVEJOB[$i]
		      unset TGRID_TRACKER[$i]
		      unset DEVICE_ID_TRACKER[$i]
		      unset ITERATION_GRID_TRACKER[$i]
		      continue
		    fi
		  #else
		    #echo "     No compressibility issues detected."
		  fi

		#Check if Restart File is present (indication job has completed)
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
		      continue 												#Case was re-started, move to the next row of ACTIVEJOB and continue checking each one for completion. 
		    
		    else 
		      echo "Job " "${ACTIVEJOB[$i]}" " failed Convergence_check at the maximum allowed time. Review the case." 
		      echo "Job " "${ACTIVEJOB[$i]}" " failed Convergence_check at the maximum allowed time. Review the case." >> ${ERROR_LOG}

		      #Clean it up?
		      if [[ "${CLEANUP}" == "TRUE" ]]; then
			CLEAN_IT_UP "${ACTIVEJOB[$i]}"
		      fi
		      unset ACTIVEJOB[$i]
		      unset TGRID_TRACKER[$i]
		      unset DEVICE_ID_TRACKER[$i]
		      unset ITERATION_GRID_TRACKER[$i]
		      continue
		    fi
		  
		  fi
		    
		
		elif [[ $(($(date +%s) - $(date -r ${ROTCFD_JOB_PATH}/${ACTIVEJOB[$i]}/${ACTIVE_FILE} +%s))) -lt "${JOBTIMER}" ]]; then
		  #echo "Still running case: ${ACTIVEJOB[$i]}"
		  continue
		  
		# If current activejob doesn't have a restart file yet, check if job has hung.
		# Equation for modification time comparison: $(($(date +%s) - $(date -r file.txt +%s))) 
		elif [[ $(($(date +%s) - $(date -r ${ROTCFD_JOB_PATH}/${ACTIVEJOB[$i]}/${ACTIVE_FILE} +%s))) -gt "${JOBTIMER}" ]]; then
		   #Kill the related process. "ps -elfyc e |grep case_name |grep -v grep |grep -v sleep" (and parse for process ID, 3rd column value)
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
		# Cleaning tasks done. Clear array values.
		echo "Case ${ACTIVEJOB[$i]} completed."
		unset ACTIVEJOB[$i]
		unset TGRID_TRACKER[$i]
		unset DEVICE_ID_TRACKER[$i]
		unset ITERATION_GRID_TRACKER[$i]
                
	done
	
	#echo "No compressibility issues detected- Flag2"

        ACTIVE_ARRAY_SIZE="${#ACTIVEJOB[@]}"
        if [[ ${ACTIVE_ARRAY_SIZE} -lt 1 ]]; then
	    RUNFLAG="FALSE"
	fi

fi


done
