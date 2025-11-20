



locals {
    clusters_data = jsondecode(file(var.clustersfile))
}
