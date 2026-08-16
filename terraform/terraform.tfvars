eks_cluster_role_arn = "arn:aws:iam::596081564794:role/LabRole"
eks_node_role_arn    = "arn:aws:iam::596081564794:role/LabRole"
kubernetes_version   = "1.35"

databases = {
  targeting = {
    allocated_storage = 20
    storage_type      = "gp2"
    username          = "admin_targeting"
    password          = "SenhaSegura123!"
    engine            = "postgres"
    instance_class    = "db.t4g.micro"
  },
  flag = {
    allocated_storage = 20
    storage_type      = "gp2"
    username          = "admin_flag"
    password          = "SenhaSegura123!"
    engine            = "postgres"
    instance_class    = "db.t4g.micro"
  },
  auth = {
    allocated_storage = 20
    storage_type      = "gp2"
    username          = "admin_auth"
    password          = "SenhaSegura123!"
    engine            = "postgres"
    instance_class    = "db.t4g.micro"
  }
}