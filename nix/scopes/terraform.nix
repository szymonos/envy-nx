# Terraform utilities - tfswitch downloads the terraform binary to ~/.local/bin
# bins: terraform tfswitch tflint
{ pkgs }: with pkgs; [
  tfswitch
  tflint
]
