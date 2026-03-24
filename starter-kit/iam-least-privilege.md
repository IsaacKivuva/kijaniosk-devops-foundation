{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowAppToReadDatabaseSecret",
      "Effect": "Allow",
      "Action": [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret"
      ],
      "Resource": "arn:aws:secretsmanager:us-east-1:123456789012:secret:prod/app/PrismaDatabaseUrl-xyz123"
    }
  ]
}