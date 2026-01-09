variable "postgres_user" {
  type    = string
  default = "pguser"
}

variable "postgres_password" {
  type      = string
  sensitive = true
  default   = "change_me"
}

variable "postgres_db" {
  type    = string
  default = "appdb"
}
