# Kubernetes bootstrap secrets + EC2 IAM



# Join command placeholder. The control-plane node overwrites this at boot
# (aws ssm put-parameter --overwrite) and workers read it to join the cluster.
resource "aws_ssm_parameter" "k8s_join_command" {
  name  = "/k8s/join-command"
  type  = "String"
  value = "placeholder"

  lifecycle {
    ignore_changes = [value] # set by the master at runtime, never by Terraform
  }
}

# Sealed-secrets private key, stored in Secrets Manager so a rebuilt cluster
# can decrypt existing SealedSecrets.


resource "aws_secretsmanager_secret" "sealed_secrets_key" {
  name                    = "my-yaml-secret"
  recovery_window_in_days = 0 # immediate delete on destroy 
}
resource "aws_secretsmanager_secret_version" "yaml_secret_version" {
  secret_id                = aws_secretsmanager_secret.sealed_secrets_key.id
  secret_string_wo         = var.sealed_secrets_key
  secret_string_wo_version = 1        # bump when the key rotates
}



# IAM policies

# Read the sealed-secrets key
resource "aws_iam_policy" "secret_access" {
  name = "secret-access-policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        Resource = aws_secretsmanager_secret.sealed_secrets_key.arn
      }
    ]
  })
}

# Read/write the join-command parameter
resource "aws_iam_policy" "ssm_join_command" {
  name = "k8s-join-command-policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:PutParameter"
        ]
        Resource = aws_ssm_parameter.k8s_join_command.arn
      }
    ]
  })
}



# IAM role + instance profile for EC2
resource "aws_iam_role" "ec2_k8s_role" {
  name = "ec2-k8s-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "secret_access" {
  role       = aws_iam_role.ec2_k8s_role.name
  policy_arn = aws_iam_policy.secret_access.arn
}

resource "aws_iam_role_policy_attachment" "ssm_join_command" {
  role       = aws_iam_role.ec2_k8s_role.name
  policy_arn = aws_iam_policy.ssm_join_command.arn
}



# What the EC2 module consumes via iam_instance_profile_name
resource "aws_iam_instance_profile" "ec2_k8s" {
  name = "ec2-k8s-instance-profile"
  role = aws_iam_role.ec2_k8s_role.name
}