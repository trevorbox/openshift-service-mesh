resource "azuread_application" "auth" {
    display_name     = "oauth2-proxy"
    sign_in_audience = "AzureADMyOrg" # Others are also supported

    web {
        redirect_uris = [
            "https://test-test.apps.ambient.sandbox3242.opentlc.com/oauth2/callback",
        ]
    }
    // We don't specify any required API permissions - we allow user consent only
}

resource "azuread_service_principal" "sp" {
    client_id                    = azuread_application.auth.client_id
    app_role_assignment_required = false
}

resource "azuread_service_principal_password" "pass" {
    service_principal_id = azuread_service_principal.sp.id
}

resource "azuread_application_federated_identity_credential" "fedcred" {
    application_id = azuread_application.auth.id # ID of your application
    display_name   = "federation-cred"
    description    = "Workload identity for oauth2-proxy"
    audiences      = ["api://AzureADTokenExchange"] # Fixed value
    issuer         = "https://trevorbox.github.io/helm-charts/"
    subject        = "system:serviceaccount:test:oauth2-proxy" # set proper NS and SA name
}
