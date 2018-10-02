Kitchen-sink repo to reproduce a bug causing jobs to be restarted unexpectedly in Nomad 0.8.3: https://github.com/hashicorp/nomad/issues/4299 .

### Issue

After batch jobs complete successfully, a subset of them get re-run unexpected later undeterministically - around 0.5-9% of jobs get retried later.

The batches are non-periodic batch jobs that successfully ran and we only submitted them once and without any retry logic.

### Steps to reproduce:

To reproduce this bug and have meaningful data, we used a combination of the following:

1. Nomad 0.8.3 modified with shorter GC interval and with more logging - based on https://github.com/hashicorp/nomad/commits/09f8815fd1f6fe9b0163c4e269c2dfe38d68bc30

2. [`bsd/nomad-metrics`](https://github.com/bsd/nomad-watcher) to we can stream and track events from nomad
3. `docker-compose` to spin up test cluster and submit jobs


Steps to run:

1. `docker-compose up -d && docker-compose scale nomad-clients=2`
2. `NOMAD_ADDR=http://<NOMAD_SERVER_IP>:4646 nomad-watcher --events-logs=./nomad-events.json`
  * _TODO_: package this into a docker container
3. Start submitting jobs repeatedly by running following on host: `while true; do date; ./submit-job ; sleep 2; done`

Run for awhile and monitor for re-run jobs, a sample way to track this is to run the following command:

```sh
docker-compose logs \
   | grep 'Total changes: (place 1)' \
   | grep -o -e 'JobID: "[^"]*' \
   | sort \
   | uniq -c \
   | sort -rn \
   | grep -v -e '^ *1 Job'
```

Eventually, the command above will report some retried jobs.

### Findings and observations

We had multiple runs, and I captured one run logs in [run-20181001_1](./run-20181001_1).  In this case, we ran ~167 jobs and 4 ran twice

```
   2 JobID: "example-1538357333-696ab8172b064d9ce92f74043ed5d21669082c88
   2 JobID: "example-1538357322-a4018605846e090717ad7d322dd6fc26355e4dee
   2 JobID: "example-1538357282-edf9086ca142f6d89e166952dd4c34a89ef707d5
   2 JobID: "example-1538356486-81b8f11c3e3fc9a0371a502ab25de1609d9768c3
```

I dug into the case of `example-1538356486-81b8f11c3e3fc9a0371a502ab25de1609d9768c3` and captured all logs and events for that job and any associated evals/allocations  in `example-1538356486-81b8f11c3e3fc9a0371a502ab25de1609d9768c3.{log|events}`.

The logs indicate that that job had two runs with roughly the following timeline

```
01:14:46
  job submitted and regsitered
  eval 19011549-97b7-3740-07cb-efb70f7f6c99 was created with `TriggerBy` `job-register`
  alloc 2bd05068-92c4-f034-174e-9c43fabf953b was created and task started on nomad client

01:14:52
  alloc 2bd05068-92c4-f034-174e-9c43fabf953b task completes and job is marked as done

01:17:13
  gc job kicks in and attempts to gc the job and all allocations
  eval b7e48b01-7b82-6df5-037d-3143c9a31188 is created with `TriggerBy` `job-deregister`
  alloc 06c7d211-fd17-31fa-c881-b883ba34487e is created referncing the job-deregister eval!!!   <--- problem here
  alloc 06c7d211-fd17-31fa-c881-b883ba34487e task starts - causing the job to be running twice!

01:17:20
  alloc 06c7d211-fd17-31fa-c881-b883ba34487e task completes

01:25:38
  gc runs and gc both eval b7e48b01-7b82-6df5-037d-3143c9a31188 and alloc 06c7d211-fd17-31fa-c881-b883ba34487e but not the job it self
```

The timeline seems to indicate that the GC activity triggers re-runs of batches, and potentially there is a race between deregistering of the jobs and cleaning up of the allocations/evals such that would trigger re-run of jobs.

### Suspicious code

While I have not investigated root cause in code yet, I noticed the following in Nomad scheduler code that seems fishy:

1. [`allocReconciler.Compute`](https://github.com/hashicorp/nomad/blob/v0.8.3/scheduler/reconcile.go#L188-L193) special case when a job is purged already or was explicitly stopped.
    * Evaluations of `job-deregister` evals for Jobs that haven't been purged from state yet will be evaluated the same way as `job-register`

2. [`allocReconciler.computePlacements`](https://github.com/hashicorp/nomad/blob/v0.8.3/scheduler/reconcile.go#L687-L694) attempts to place new allocations if existing allocs (as determined by expecting state through its caller `allocReconciler.computeGroup`) is less the expected
    * Potentially there is a race here between alloc state and job - if the allocs are reaped before or while `Compute` runs, we may end up with new allocations being made!

3. [`job.BatchDeregister`](https://github.com/hashicorp/nomad/blob/v0.8.3/nomad/job_endpoint.go#L708-L717) does not set `JobModifyIndex` and neither does [`nomadFSM.applyBatchDeregisterJob`](https://github.com/hashicorp/nomad/blob/v0.8.3/nomad/fsm.go#L510-L525)
    * Similar [`job.Deregister`](https://github.com/hashicorp/nomad/blob/v0.8.3/nomad/job_endpoint.go#L603-L640), uses the same flow of deregistering/purging job first then inserts associated evals
    * But `job.Deregister` manages `JobModifyIndex` carefully so that eval references job post-deregistering
    * I wonder if this results into a race in what order evaluations and state modifications are applied

While I debug the problem further, I'd update points here (unless underlying causes are identified or addressed by then).
