#!/bin/bash
#
# VerifyCopiedJobs.sh
#
# ------------------------------------------------------------------------
# 20181028 - Changelog moved to bottom of script.
# ------------------------------------------------------------------------
#
# BSD 2-Clause License
#
# Copyright (c) 2018 - 2023, William A. Arlofski waa-at-revpol-dot-com
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are
# met:
#
# 1.  Redistributions of source code must retain the above copyright
# notice, this list of conditions and the following disclaimer.
#
# 2.  Redistributions in binary form must reproduce the above copyright
# notice, this list of conditions and the following disclaimer in the
# documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS
# IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED
# TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A
# PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
# HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
# SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED
# TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
# PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
# LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
# NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
# SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
#
# ------------------------------------------------------------------------

# Set some variables
# ------------------
bcbin="/opt/bacula/bin/bconsole"
bcconfig="/opt/bacula/etc/bconsole.conf"

# --------------------------------------------------
# Nothing should need to be modified below this line
# --------------------------------------------------

# ================================================================================================================
#
# NOTES:
#
# - From the bconsole command line, the Verify "Level=Data" Job *requires* the correct client, and
#   storage used for the Copied job, otherwise it will use the one in the Restore Job resource specified!
# - When called from a RunScript{} (RunsWhen = After) in a Copy Job, we need to pass %i (jobid)
#
# - A Sample Copy Job resource which calls this script in a RunsScript {RunsWhen = after}
# ----8<----
# Job {
#   Name = CopyJobsAndVerifyThem
#   JobDefs = Defaults
#   Type = Copy
#   Client = None   # Must be a valid Client resource, but will be overridden on the command line
#   Level = Full    # Required but will be overridden on the command line
#   FileSet = None  # Must be a valid FileSet resource, but will be overridden on the command line
#   Messages = Standard
#   Priority = 10
#   Pool = SourceBackupPool      # Pool to look in for jobs to be copied when using the PoolUncopiedJobs SelectionType
#   Storage = SomeStorageResource
#   MaximumConcurrentJobs = 10  # Optional
#
#   # Use the simple "PoolUncopiedJobs" Selection type. This
#   # will copy all uncopied jobs in the Pool specified in this Copy Job
#   # ------------------------------------------------------------------
#   SelectionType = PoolUncopiedJobs
#
#   # Some samples using the SQLQuery SelectionType
#   # ---------------------------------------------
#   # Selection Type = SQLQuery
#   #
#   # Just send a specific list of some jobids
#   # ----------------------------------------
#   # Selection Pattern = "SELECT JobId FROM Job WHERE (JobId='26287' OR JobId='26288' OR JobId='26315' OR JobId='26316');"
#
#   # Copy all backup jobs from all pools that terminated OK in the past 24 hours whose name begins with "dns"
#   # --------------------------------------------------------------------------------------------------------
#   # Selection Pattern = "SELECT JobId FROM Job WHERE Type='B' AND JobStatus='T' AND Name LIKE 'dns%' AND RealEndTime >= (current_timestamp - interval '24 hours') ORDER BY JobId;"
#
#   # Copy all backup jobs from all pools that terminated OK in the past 24 hours
#   # ---------------------------------------------------------------------------
#   # Selection Pattern = "SELECT JobId FROM Job WHERE Type='B' AND JobStatus='T' AND RealEndTime >= (current_timestamp - interval '24 hours') ORDER BY JobId;"
#
#   RunScript {
#     RunsWhen = after
#     RunsOnClient = no
#     Command = /path/to/VerifyCopyJobs.sh %i"    # Call this script and pass this Copy 'control' Job's jobid
#   }
# }
# ----8<----
#
# - We need a valid Job resource of "Type = Verify". You cannot pass the Priority of a job on the command line,
#   so we need to have this special "Verify" Job with the right priority set.
# ----8<----
# Job {
#   Name = Verify_Copy_Jobs
#   Type = Verify
#   Priority = 10             # Priority must be same as the Copy Job job that calls it otherwise it
#                             # will never start due to the Copy Job that called it is actually still
#                             # running at a different priority
#   JobDefs = Defaults        # Is a good idea to have a special JobDefs defined for use. Would require less
#                             # things to be specified on the command line by this script
#   Level = VolumeToCatalog   # Place holder. Level will be specified onthe command line
#   FileSet = None            # Must be a valid FileSet, but is not used
#   Client = None             # Must be a valid Client resource, but will be overridden on the command line
#   Pool = None               # Must be a valid Pool resource, but will be overriddedn on the command line
#   Storage = aoe-file        # Must me a valid Storage resource, but will be overridden on the command line
#   AllowDuplicateJobs = yes  # Optional, but if your Copy job spawns more than one Copy, then this will need
#                             # to be increased
#   MaximumConcurrentJobs = 5 # Optional
# }
# ----8<----
#
# - A sample Pool resource having the required "NextPool = xxx" option defined for Copy/Migration/VFull jobs
# ----8<----
#
# Pool {
#   Name = SourceBackupPool
#   Storage = SomeStorageResource
#   PoolType = Backup
#   Recycle = yes
#   AutoPrune = no
#   VolumeRetention = 5w
#   MaximumVolumeBytes = 10g
#   ActionOnPurge = Truncate
#   NextPool = AoE-File-Full     # This can also be overridden in a Job (Or Schedule)
# }
# ----8<----
#
# ================================================================================================================

# Simple test to verify at least one command line argument was supplied
# ---------------------------------------------------------------------
if [ $# -lt 1 ]; then
  echo -e "\nUse: $0 <jobid>"
  echo -e "Command line received: $0 $@\n"
  exit 1
fi

# Verify that the bconsole config file exists
# -------------------------------------------
if [ ! -e ${bcconfig} ]; then
  echo -e "\nThe bconsole configuration file does not seem to be '${bcconfig}'."
  echo -e "Please check the setting for the variable 'bcconfig'.\n"
  exit 1
fi

# Verify that the bconsole binary exists and is executable
# --------------------------------------------------------
if [ ! -x ${bcbin} ]; then
  echo -e "\nThe bconsole binary does not seem to be '${bcbin}', or it is not executable."
  echo -e "Please check the setting for the variable 'bcbin'.\n"
  exit 1
fi

echo "===================================================="
echo "Command line required: $0 <jobid>"
echo "Command line received: $0 $@"
echo "===================================================="

# First, we need to get the list of Jobs that were queued to be copied
# --------------------------------------------------------------------
#
# !!IMPORTANT!!
# The 'primary' Copy Job that selects jobs to be copied spawns Copy Jobs
# but is also in charge of copying one of the jobs! So it spawns n-1 number
# of Copy Jobs.
#
# This complicates matters a lot, but I think I have handled it quite OK.
#
# We grab the "Copying JobId [0-9]\+ started." line entries in the 'primary'
# Copy Job to directly obtain the Copy Jobs' jobids to check their summaries
# for "New JobId:" to get the Copied jobs to run Verify Job(s) against.
#
# Additionally, because the 'primary' Copy Job handles one Copy Job, we need
# to look at this 'primary' Copy Job to gather some information too.
#
# --------------------------------------------------------------------------
echo "Parsing the job log of jobid: $1"
currentjoblog=$(echo -e "llist joblog jobid=$1\nquit\n" | ${bcbin} -nc ${bcconfig})

echo "Verifying this is a copy job..."
jobtype=$(echo "${currentjoblog}" | grep "type: " | cut -d: -f2 | tr -d ' ')
if [ X${jobtype} != 'Xc' ]; then
  echo "This is not a Copy Job. Aborting..."
  exit 1
  else
    echo "This is a Copy Job."
fi

echo "Checking to see if this job completed OK..."
jobstatus=$(echo "${currentjoblog}" | grep "jobstatus: " | cut -d: -f2 | tr -d ' ')
if [ X${jobstatus} != 'XT' ];then
  echo "This Copy Job did not terminate OK. Aborting..."
  exit 1
  else
    echo "This Copy Job terminated OK."
fi

# -----------------------------------------------------------------------------
# The easy way to determine the Backup jobs that were selected to be copied is
# to simply grep this current Copy Job's log for the following line:
#
# "bacula-dir JobId 26334: The following # JobIds were chosen to be copied: 111,222,333,444
#
# However, I think a better way is to make sure Copy jobs were actually spawned,
# and then use those jobids. Additionally, it seems like this Copy control Job always
# chooses the last jobid in the list to handle itself, but will this always be true?
#
# So, instead we grep for the following lines:
#
# "bacula-dir JobId 26334: Copying JobId 111 started."
#
# From each of these Copy Jobs we can then determine the "New Backup JobId"
# that we need to run the "Verify level=data" on, and we can also find the
# "Prev JobId" to be able to determine the Client that was used in the original
# Backup Job. This Client is necessary for running a "Verify level=Data" Job.
#
# And finally, we need to get this same information from this 'primary' Copy
# Job which spawns the rest of the Copy Jobs.
# -----------------------------------------------------------------------------


# Set and print some variables from the current 'primary' Copy Job's joblog
# -------------------------------------------------------------------------
let errors="0"
thiscopyjobid=$1
spawnedcopyjobids=$(echo "${currentjoblog}" | grep "Copying JobId [0-9]\+ started." | awk '{print $7}')
echo "================================================================================="
echo -n "Backup jobids selected to be copied: "
echo "${currentjoblog}" | grep "chosen to be copied:" | cut -d, -f1- | cut -d: -f4- | tr -d ' ' | tr , ' '
echo "================================================================================="
echo "Copy Jobs spawned by this primary Copy Job (jobid=${thiscopyjobid}):"
echo "${spawnedcopyjobids}"
echo "================================================================================="
echo -n "New JobId of Backup Job copied by this 'primary' Copy Job: "
echo "${currentjoblog}" | grep "New Backup JobId:" | awk '{print $4}'
echo "================================================================================="

for copyjobid in ${thiscopyjobid} ${spawnedcopyjobids}; do
  echo "--"
  echo -n "Checking Copy Job with jobid=${copyjobid} for New Backup JobId..."
  newjobid=$(echo -e "llist joblog jobid=${copyjobid}\nquit\n" \
  | ${bcbin} -nc ${bcconfig} | grep "New Backup JobId: " \
  | cut -d: -f2 | tr -d ' ')

  # If the Copy Job had copied zero files, then the "New Backup JobId"
  # that is set in the Copy Job's log is '0', so we skip this Copy Job
  # ------------------------------------------------------------------
  if [ ${newjobid} -eq 0 ]; then
    echo "  Zero files copied. Nothing to verify."
    else
    echo "  Found jobid=${newjobid}"

    # Verify that the Copy Job terminated OK before running any Verify Job against it
    # -------------------------------------------------------------------------------
    echo "Checking to see if this Copy Job (jobid=${copyjobid}) completed OK..."
    jobstatus=$(echo -e "llist joblog jobid=${copyjobid}\nquit\n" \
    | ${bcbin} -nc ${bcconfig} | grep "jobstatus: " | cut -d: -f2 | tr -d ' ')
    if [ X${jobstatus} = 'XT' ];then
      echo "This Copy Job terminated OK. Will trigger a Verify Job."

      # Now we need to get the Client from the job log of the
      # 'previous jobid' (the original backup job actually)
      # -----------------------------------------------------
      currentcopyjoblog=$(echo -e "llist joblog jobid=${copyjobid}\nquit\n" | ${bcbin} -nc ${bcconfig})
      prevjobid=$(echo "${currentcopyjoblog}" | grep "Prev Backup JobId:" | awk '{print $4}' | tr -d '"')
      previousjoblog=$(echo -e "llist joblog jobid=${prevjobid}\nquit\n" | ${bcbin} -nc ${bcconfig}) 
      client=$(echo "${previousjoblog}" | grep "^  Client:" | cut -d: -f2 | cut -d '"' -f2)
      jobname=$(echo "${previousjoblog}" | grep "^  Job:" | awk '{print $2}' | sed 's/\(^.*\)\.[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}.*/\1/')
      echo "Found Client: ${client}"
      echo "Found Job Name: ${jobname}"

      # And finally, queue a Verify Job against the Copied Job with all the information we have gathered
      # ------------------------------------------------------------------------------------------------
      echo "Queueing DATA Verify Job of Copied Job with jobid=${newjobid}"
      echo -e "run job=Verify jobid=${newjobid} client=${client} level=data comment=\"Data Verify of Copied Backup Job: ${jobname} (jobid: ${newjobid})\" accurate=yes yes\nquit\n" \
      | ${bcbin} -nc ${bcconfig} | grep "^run\|^Job queued."
      else
        echo "This Copy Job did not terminate OK. Not queueing a Verify Job..."
        let errors=${errors}+1
    fi
  fi
done
echo "--"
echo -e "\nFinished...\n"
echo "Total errors: ${errors}"
echo "Exiting with error level: ${errors}"
exit ${errors}
# -------------
# End of script
# -------------

# ----------
# Change Log
# ----------
# ----------------------------
# William A. Arlofski
# waa@protonmail.com
# ----------------------------
# 20181028 - Initial release
#          - Given a Copy Job's jobid, find all Backup jobids that were selected
#            to be copied and run a Verify level=Data against each Copied Job's
#            "New Backup JobId".
#
#          - May be run manually, via cron, or triggered in a RunScript of a
#            Copy Job or Admin Job, or any Job really...
# 20230613 - Add explicit linefeeds and quit commands to all bconsole command
#            lines where they are missing. Thank you to Howard Mccaslin for
#            pointing this inconsistency out to me.
#          - Clean up script a bit, replacing tabs with spaces and remove extra
#            lines.
# -------------------------------------------------------------------------------
