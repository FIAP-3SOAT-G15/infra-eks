variable "region" {
  type    = string
  default = "us-east-1"
}

variable "tags" {
  type = map(string)
  default = {
    managed_by_terraform = true
  }
}

variable "cognito_policy" {
  type    = string
  default = "arn:aws:iam::202062340677:policy/TechChallengeCognitoReadOnlyPolicy"
}