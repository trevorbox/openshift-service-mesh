# notes on egress

This is an interesting observation <https://github.com/istio/istio/issues/55163>.

Apparently any ServiceEntry will match the host from anywhere in the mesh. So instead - you use an AuthorizationPolicy and define only the services to allow. It means you will be explicitly denied unless you have a waypoint in a namespace that can access hosts externally.
