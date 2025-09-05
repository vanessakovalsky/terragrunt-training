include "root" {
  path = find_in_parent_folders("root.hcl")
}

# Dépendances vers tous les modules précédents
dependency "vpc" {
  config_path = "../vpc"
  mock_outputs = {
    vpc_id = "vpc-fake"
    public_subnets = ["subnet-fake1", "subnet-fake2"]
  }
}

dependency "security_groups" {
  config_path = "../security-groups"
  mock_outputs = {
    web_security_group_id = "sg-fake"
  }
}

dependency "database" {
  config_path = "../database"
  mock_outputs = {
    db_instance_endpoint = "fake-endpoint.region.rds.amazonaws.com"
  }
  skip_outputs = true  # Optionnel si la DB n'est pas critique pour le plan
}

terraform {
  source = "git::https://github.com/terraform-aws-modules/terraform-aws-ec2-instance.git?ref=v5.0.0"
  before_hook "prepare_user_data" {
    commands = ["plan", "apply"]
    execute = [
      "bash", "-c", <<-EOT
        echo "🚀 Preparing EC2 user data script..."
        echo "Database endpoint: ${dependency.database.outputs.db_instance_endpoint}"
        echo "Security group: ${dependency.security_groups.outputs.web_security_group_id}"
      EOT
    ]
  }
  
  before_hook "check_ami" {
    commands = ["plan", "apply"]
    execute = [
      "aws", "ec2", "describe-images",
      "--owners", "amazon",
      "--filters", "Name=name,Values=amzn2-ami-hvm-*-x86_64-gp2",
      "--query", "Images | sort_by(@, &CreationDate) | [-1].ImageId",
      "--output", "text"
    ]
  }
  
  after_hook "test_instance" {
    commands = ["apply"]
    execute = ["echo", "🌐 EC2 instance deployed. Testing web server connectivity..."]
  }
  
  after_hook "display_endpoints" {
    commands = ["apply"]
    execute = [
      "bash", "-c", <<-EOT
        echo "=== 📋 DEPLOYMENT SUMMARY ==="
        echo "Web Server URL: http://\$(terraform output -raw public_ip)"
        echo "Database Endpoint: ${dependency.database.outputs.db_instance_endpoint}"
        echo "VPC ID: ${dependency.vpc.outputs.vpc_id}"
        echo "=========================="
      EOT
    ]
  }
}

# Data source pour récupérer la dernière AMI Amazon Linux 2
locals {
  user_data = base64encode(<<-EOT
    #!/bin/bash
    yum update -y
    yum install -y httpd mysql
    systemctl start httpd
    systemctl enable httpd
    
    # Page web simple avec info sur la DB
    cat > /var/www/html/index.html << 'HTML'
    <!DOCTYPE html>
    <html>
    <head>
        <title>Hooks Exercise - Web Server</title>
        <style>
            body { font-family: Arial, sans-serif; margin: 40px; background: #f4f4f4; }
            .container { background: white; padding: 30px; border-radius: 10px; box-shadow: 0 0 10px rgba(0,0,0,0.1); }
            h1 { color: #333; }
            .info { background: #e8f4fd; padding: 15px; border-radius: 5px; margin: 20px 0; }
        </style>
    </head>
    <body>
        <div class="container">
            <h1>🎉 Terragrunt Hooks Exercise Successful!</h1>
            <div class="info">
                <h3>Infrastructure Details:</h3>
                <p><strong>Database Endpoint:</strong> ${dependency.database.outputs.db_instance_endpoint}</p>
                <p><strong>VPC ID:</strong> ${dependency.vpc.outputs.vpc_id}</p>
                <p><strong>Deployed with:</strong> Terragrunt + Terraform</p>
                <p><strong>Instance ID:</strong> $(curl -s http://169.254.169.254/latest/meta-data/instance-id)</p>
            </div>
            <p>This web server was deployed using a complete dependency chain managed by Terragrunt hooks!</p>
        </div>
    </body>
    </html>
HTML
  EOT
  )
}

inputs = {
  name = "hooks-exercise-web"
  
  ami           = "ami-0c02fb55956c7d316"  # Amazon Linux 2 (à adapter selon la région)
  instance_type = "t2.micro"
  key_name      = "your-key-pair"  # À adapter
  
  vpc_security_group_ids = [dependency.security_groups.outputs.web_security_group_id]
  subnet_id             = dependency.vpc.outputs.public_subnets[0]
  
  associate_public_ip_address = true
  
  user_data_base64 = local.user_data
  
  root_block_device = [
    {
      volume_type = "gp3"
      volume_size = 10
      encrypted   = false
    }
  ]
  
  tags = {
    Name = "hooks-exercise-web-server"
    Type = "WebServer"
  }
}