-- Records one memory sample.  Low weight, and it runs in the same backend as
-- the workload, which is the only place pg_backend_memory_contexts can see it.
SELECT mm_sample();
