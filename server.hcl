log_level    = "DEBUG"
enable_debug = true
leave_on_interrupt = false
leave_on_terminate = true
disable_update_check = true
data_dir = "/opt/nomad"
bind_addr = "0.0.0.0"
region     = "global"
datacenter = "default"


# Do not use Consul -- even if a Consul agent is found by accident.
consul {
    auth             = "no:consul"
    auto_advertise   = false
    client_auto_join = false
    server_auto_join = false
}

server {
    enabled          = true
    bootstrap_expect = 3
    raft_protocol    = 3
    retry_join = [
        "nomad-server-1",
        "nomad-server-2",
        "nomad-server-3",
    ]

    job_gc_threshold  = "30s"
    eval_gc_threshold = "10s"
    node_gc_threshold = "1h"
}
