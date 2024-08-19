provider "aws" {
  region = "eu-west-2"
}

# Create a VPC
resource "aws_vpc" "my_vpc" {
  cidr_block = "10.0.0.0/16"
  tags = {
    Name = "Setup1_VPC"
  }
}

# Create an Internet Gateway (IGW)
resource "aws_internet_gateway" "my_igw" {
  vpc_id = aws_vpc.my_vpc.id
  tags = {
    Name = "Setup1_IGW"
  }
}

# Create an Elastic IP for NAT Gateway
resource "aws_eip" "nat_eip" {
  domain = "vpc"
  tags = {
    Name = "Setup1_NAT_EIP"
  }
}

# Create a NAT Gateway in the public subnet
resource "aws_nat_gateway" "nat_gw" {
  allocation_id = aws_eip.nat_eip.id
  subnet_id     = aws_subnet.public_subnet.id
  tags = {
    Name = "Setup1_NAT_Gateway"
  }
}

# Create a public subnet
resource "aws_subnet" "public_subnet" {
  vpc_id            = aws_vpc.my_vpc.id
  cidr_block        = "10.0.1.0/24"
  map_public_ip_on_launch = true
  availability_zone = "eu-west-2a" 
  tags = {
    Name = "setup1_public_subnet"
  }
}

# Create a second public subnet in a different availability zone
resource "aws_subnet" "public_subnet_2" {
  vpc_id            = aws_vpc.my_vpc.id
  cidr_block        = "10.0.3.0/24"
  map_public_ip_on_launch = true
  availability_zone = "eu-west-2b"
  tags = {
    Name = "setup1_public_subnet_2"
  }
}

# Create a private subnet
resource "aws_subnet" "private_subnet" {
  vpc_id            = aws_vpc.my_vpc.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "eu-west-2a" 
  tags = {
    Name = "setup1_private_subnet"
  }
}

# Create a public route table
resource "aws_route_table" "public_route_table" {
  vpc_id = aws_vpc.my_vpc.id
  tags = {
    Name = "setup1_public_route_table"
  }
}

# Create a private route table
resource "aws_route_table" "private_route_table" {
  vpc_id = aws_vpc.my_vpc.id
  tags = {
    Name = "setup1_private_route_table"
  }
  # Route private subnet traffic to the NAT Gateway
  route {
    cidr_block = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat_gw.id
  }
}

# Associate the public route table with the public subnet
resource "aws_route_table_association" "public_route_table_association" {
  subnet_id      = aws_subnet.public_subnet.id
  route_table_id = aws_route_table.public_route_table.id
}

# Create a route to the Internet Gateway
resource "aws_route" "internet_access" {
  route_table_id         = aws_route_table.public_route_table.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.my_igw.id
}

# Associate the private route table with the private subnet
resource "aws_route_table_association" "private_route_table_association" {
  subnet_id      = aws_subnet.private_subnet.id
  route_table_id = aws_route_table.private_route_table.id
}

######################################################################
# Create a security group for Load Balancer
resource "aws_security_group" "lb_sg" {
  vpc_id = aws_vpc.my_vpc.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "Setup1_LB_SG"
  }
}

# Create a security group for EC2 instances
resource "aws_security_group" "ec2_sg" {
  vpc_id = aws_vpc.my_vpc.id

  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.lb_sg.id] # Allow traffic only from the LB security group
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "Setup1_EC2_SG"
  }
}

# Create a load balancer
resource "aws_lb" "my_lb" {
  name               = "my-lb"
  
  load_balancer_type = "application"
  security_groups    = [aws_security_group.lb_sg.id]
  subnets            = [aws_subnet.public_subnet.id, aws_subnet.public_subnet_2.id]
  

  tags = {
    Name = "Setup1_LB"
  }
}

# Create a listener for the load balancer
resource "aws_lb_listener" "my_lb_listener" {
  load_balancer_arn = aws_lb.my_lb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.my_target_group.arn
  }
}

# Create a target group for the load balancer
resource "aws_lb_target_group" "my_target_group" {
  name        = "my-targets"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = aws_vpc.my_vpc.id
  target_type = "instance"

  health_check {
    healthy_threshold   = 3
    unhealthy_threshold = 2
    timeout             = 5
    interval            = 30
    path                = "/"
  }

  tags = {
    Name = "Setup1_Target_Group"
  }
}

# Create a launch template
resource "aws_launch_template" "my_launch_template" {
  name_prefix   = "my-launch-template"
  image_id      = "ami-05ea2888c91c97ca7" #ami from the specified region
  instance_type = "t2.micro"

  user_data = base64encode(<<-EOT
                #!/bin/bash
                yum update -y
                yum install -y httpd
                systemctl start httpd
                systemctl enable httpd
              EOT
  )

  key_name = "my-key"

  network_interfaces {
    associate_public_ip_address = false
    security_groups             = [aws_security_group.ec2_sg.id]
    subnet_id                   = aws_subnet.private_subnet.id
  }

  tag_specifications {
    resource_type = "instance"

    tags = {
      Name = "Setup1_ASG_Instance"
    }
  }
}

# Create an Auto Scaling Group
resource "aws_autoscaling_group" "my_asg" {
  desired_capacity     = 2
  max_size             = 3
  min_size             = 1
  vpc_zone_identifier  = [aws_subnet.private_subnet.id]
  launch_template {
    id      = aws_launch_template.my_launch_template.id
    version = "$Latest"
  }

  target_group_arns = [aws_lb_target_group.my_target_group.arn]

  tag {
    key                 = "Name"
    value               = "Setup1_ASG_Instance"
    propagate_at_launch = true
  }

  lifecycle {
    create_before_destroy = true
  }
}
