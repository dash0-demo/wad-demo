terraform {
  backend "gcs" {
    # Bucket name and prefix are supplied at init time so the same code can
    # target different state buckets:
    #
    #   terraform init \
    #     -backend-config="bucket=<TF_STATE_BUCKET>" \
    #     -backend-config="prefix=wad-demo/gke"
  }
}
