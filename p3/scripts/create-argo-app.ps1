
$appName = "my-app"
$repoURL = "https://github.com/mustafaUrl/Inception-of-Things.git"

$pathInRepo = "p3/manifests" 
$destServer = "https://kubernetes.default.svc"
$destNamespace = "default"
$syncPolicy = "automatic"

Write-Host "Creating the Argo CD application: $($appName)..." -ForegroundColor Cyan

argocd app create $appName `
  --repo $repoURL `
  --path $pathInRepo `
  --dest-server $destServer `
  --dest-namespace $destNamespace `
  --sync-policy $syncPolicy

if ($LASTEXITCODE -eq 0) {

  Write-Host "Argo CD app '$($appName)' was successfully created." -ForegroundColor Green
  Write-Host "Check the Argo CD UI: https://localhost:8080 (if port-forwarding is working)" -ForegroundColor Green
  Write-Host "To check the application status: argocd app get $($appName)" -ForegroundColor Green
} else {
  Write-Error "An error occurred while creating the Argo CD app. Please check the output above."
}