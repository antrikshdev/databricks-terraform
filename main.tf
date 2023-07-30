data "azurerm_client_config" "current" {
}

resource "azurerm_resource_group" "mgm" {
  name     = var.resource_group
  location = var.location-rg
}

resource "azurerm_virtual_network" "mgm" {
  name                = "databricks-vnet"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.mgm.location
  resource_group_name = azurerm_resource_group.mgm.name
}

resource "azurerm_subnet" "publicmgm" {
  name                 = "public-subnet"
  resource_group_name  = azurerm_resource_group.mgm.name
  virtual_network_name = azurerm_virtual_network.mgm.name
  address_prefixes     = ["10.0.1.0/24"]
  delegation {
    name = "databricks-delegation"

    service_delegation {
      name = "Microsoft.Databricks/workspaces"
      actions = [
        "Microsoft.Network/virtualNetworks/subnets/join/action",
        "Microsoft.Network/virtualNetworks/subnets/prepareNetworkPolicies/action",
        "Microsoft.Network/virtualNetworks/subnets/unprepareNetworkPolicies/action",
      ]
    }
  }
}
resource "azurerm_subnet" "privatemgm" {
  name                 = "private-subnet"
  resource_group_name  = azurerm_resource_group.mgm.name
  virtual_network_name = azurerm_virtual_network.mgm.name
  address_prefixes     = ["10.0.0.0/24"]
  delegation {
    name = "databricks-delegation"

    service_delegation {
      name = "Microsoft.Databricks/workspaces"
      actions = [
        "Microsoft.Network/virtualNetworks/subnets/join/action",
        "Microsoft.Network/virtualNetworks/subnets/prepareNetworkPolicies/action",
        "Microsoft.Network/virtualNetworks/subnets/unprepareNetworkPolicies/action",
      ]
    }
  }
}

resource "azurerm_network_security_group" "public-nsg-mgm" {
  name                = "public-nsg"
  location            = azurerm_resource_group.mgm.location
  resource_group_name = azurerm_resource_group.mgm.name
}
resource "azurerm_network_security_group" "private-nsg-mgm" {
  name                = "private-nsg"
  location            = azurerm_resource_group.mgm.location
  resource_group_name = azurerm_resource_group.mgm.name
}

resource "azurerm_subnet_network_security_group_association" "public-associate-mgm" {
  subnet_id                 = azurerm_subnet.publicmgm.id
  network_security_group_id = azurerm_network_security_group.public-nsg-mgm.id
}

resource "azurerm_subnet_network_security_group_association" "private-associate-mgm" {
  subnet_id                 = azurerm_subnet.privatemgm.id
  network_security_group_id = azurerm_network_security_group.private-nsg-mgm.id
}

resource "azurerm_databricks_workspace" "mgm" {
  name                        = "databricks-workspace"
  resource_group_name         = azurerm_resource_group.mgm.name
  location                    = azurerm_resource_group.mgm.location
  sku                         = "standard" # Change to "premium" if required
  managed_resource_group_name = "managed-databricks-workspace"
  tags = {
    Environment = "Production"
  }

  custom_parameters {
    no_public_ip                                         = true
    virtual_network_id                                   = azurerm_virtual_network.mgm.id
    public_subnet_name                                   = azurerm_subnet.publicmgm.name
    private_subnet_name                                  = azurerm_subnet.privatemgm.name
    public_subnet_network_security_group_association_id  = azurerm_subnet_network_security_group_association.public-associate-mgm.subnet_id
    private_subnet_network_security_group_association_id = azurerm_subnet_network_security_group_association.private-associate-mgm.subnet_id
  }
}

data "databricks_node_type" "smallest" {
  depends_on = [azurerm_databricks_workspace.mgm]
  local_disk = true
}

data "databricks_spark_version" "latest_lts" {
  depends_on        = [azurerm_databricks_workspace.mgm]
  long_term_support = true
}

resource "databricks_instance_pool" "pool" {
  instance_pool_name                    = "mgmpool"
  min_idle_instances                    = 1
  max_capacity                          = 10
  node_type_id                          = data.databricks_node_type.smallest.id
  idle_instance_autotermination_minutes = 10
}

resource "databricks_cluster" "shared_autoscaling" {
  depends_on              = [azurerm_databricks_workspace.mgm]
  instance_pool_id        = databricks_instance_pool.pool.id
  cluster_name            = "My Cluster"
  spark_version           = data.databricks_spark_version.latest_lts.id
  num_workers             = 1
  autotermination_minutes = 20
  spark_conf = {
    "spark.databricks.io.cache.enabled" : true
  }
  custom_tags = {
    "createdby" = "Mr Devgan"
  }
}

/* resource "databricks_notebook" "this" {
  path     = "/firstnotebook.py"
  language = var.notebook_language
  source   = "firstnotebook.py"
} */

resource "databricks_job" "this" {
  depends_on          = [databricks_cluster.shared_autoscaling]
  name                = var.job_name
  existing_cluster_id = databricks_cluster.shared_autoscaling.cluster_id
  # job schedule
  schedule {
    quartz_cron_expression = "* * * * * ?" # cron schedule of job
    timezone_id            = "UTC"
  }
  git_source {
    url      = var.github_url
    provider = var.repo_provider
    branch   = var.branch
  }
  spark_python_task {
    python_file = var.python_file
    source      = "GIT"
  }
}


