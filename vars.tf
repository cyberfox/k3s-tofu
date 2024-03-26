variable "virtual_environment" {
  type = object({
                  username = string
                  password = string
                  endpoint = string
                })
  sensitive = true
}
