/**
 * This module creates a global loadbalancer, backed by a kubernetes service.
 * The service can be present in multiple clusters in any number of regions.
 *
 * The `backends.service_obj` items are `kubernetes_service` objects.
 *
 * To use services from different kubernetes clusters, you will need to use
 * multiple kubernetes providers, using provider aliases.
 */

# Copyright 2024 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

data "google_client_config" "default" {}

resource "terraform_data" "neg-helpers" {
  for_each = var.backends
  input = {
    svc_port = tostring(each.value.service_obj.spec.0.port.0.port)
    negnotes = jsondecode(each.value.service_obj.metadata[0].annotations["cloud.google.com/neg-status"])
    negname  = jsondecode(each.value.service_obj.metadata[0].annotations["cloud.google.com/neg-status"])["network_endpoint_groups"][tostring(each.value.service_obj.spec.0.port.0.port)]
    negzones = jsondecode(each.value.service_obj.metadata[0].annotations["cloud.google.com/neg-status"])["zones"]
  }
}

data "google_compute_network_endpoint_group" "backend_negs" {
  for_each = terraform_data.neg-helpers
  name     = each.value.output.negname
  zone     = each.value.output.negzones[0]
}

resource "google_compute_backend_service" "default" {
  name                  = var.lb_name
  load_balancing_scheme = "EXTERNAL_MANAGED"
  protocol              = "HTTP"
  health_checks         = [google_compute_health_check.default.id]
  // for demonstration, use a random backend.
  locality_lb_policy = "RANDOM"
  // NEGS go here.
  // NOTE: zero is not a valid max_rate. must remove whole block to drain.
  dynamic "backend" {
    for_each = var.backends
    content {
      group                 = data.google_compute_network_endpoint_group.backend_negs[backend.key].id
      balancing_mode        = "RATE"
      max_rate_per_endpoint = 100
      description = format("Kubernetes service %s/%s",
        backend.value.service_obj.metadata[0].namespace,
      backend.value.service_obj.metadata[0].name)
    }
  }
}

// Health check, using the serving port on the kubernetes service object.
resource "google_compute_health_check" "default" {
  name               = "${var.lb_name}-healthcheck"
  check_interval_sec = 3
  timeout_sec        = 2
  healthy_threshold  = 1
  http_health_check {
    port = 8080
  }
}

resource "google_compute_url_map" "default" {
  name            = "${var.lb_name}-urlmap"
  default_service = google_compute_backend_service.default.id
}

resource "google_compute_target_http_proxy" "default" {
  name    = "${var.lb_name}-proxy"
  url_map = google_compute_url_map.default.id
}

resource "google_compute_global_forwarding_rule" "default" {
  name                  = "${var.lb_name}-fr"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  port_range            = "80"
  target                = google_compute_target_http_proxy.default.id
}

