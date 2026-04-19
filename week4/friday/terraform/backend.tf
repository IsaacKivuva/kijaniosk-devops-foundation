terraform {
  backend "s3" {
    bucket         = "week5-jenkins-2111-2550-8279"
    key            = "week5/jenkins"
    region         = "af-south-1"
    dynamodb_table = "jenkins-2111-2550-8279"
    encrypt        = true
  }
}