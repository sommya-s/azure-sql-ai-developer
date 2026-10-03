# Build a self-contained DAB image with the config baked in (pin the tag to a specific version in production)
FROM mcr.microsoft.com/azure-databases/data-api-builder:latest
COPY dab-config.json /App/dab-config.json
# DAB_CONNECTION_STRING and APPLICATIONINSIGHTS_CONNECTION_STRING come from the container app's settings.
