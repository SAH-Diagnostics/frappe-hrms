# Testing GitHub Actions Deployment with act-cli

This guide explains how to test the deployment workflow locally using act-cli before pushing to GitHub.

## Prerequisites

1. **Install act-cli**:
   - macOS: `brew install act`
   - Linux: `curl https://raw.githubusercontent.com/nektos/act/master/install.sh | sudo bash`
   - Windows: `choco install act-cli` or download from [releases](https://github.com/nektos/act/releases)

2. **Docker**: Ensure Docker is running on your machine

3. **AWS Credentials**: Update the `.secrets` file with your AWS credentials

## Configuration

The `.secrets` file in the project root contains the required secrets:

```bash
# AWS Credentials
AWS_ACCESS_KEY_ID=your_access_key_id
AWS_SECRET_ACCESS_KEY=your_secret_access_key
AWS_REGION=eu-west-2
AWS_SECRETS_REGION=eu-north-1
AWS_DEPLOY_SECRET_ID=arn:aws:secretsmanager:eu-north-1:280648354859:secret:prod/frappe-Aojmb0
```

## Testing the Workflow

### 1. Dry Run (List jobs without execution)
```bash
act -l
```

This will show all available jobs and events.

### 2. Test Specific Job
```bash
# Test the deploy job on push event
act push -j deploy --secret-file .secrets -n

# -n flag performs a dry run without executing
```

### 3. Full Execution
```bash
# Run the full deployment workflow
act push -j deploy --secret-file .secrets

# Or run on main branch push
act push --secret-file .secrets
```

### 4. Interactive Mode
```bash
# Run with verbose output
act push -j deploy --secret-file .secrets -v

# Run with interactive shell on failure
act push -j deploy --secret-file .secrets --shell
```

## Debugging

### Check Workflow Syntax
```bash
# Validate the workflow file
act -l
```

If you see the job listed, the syntax is valid.

### View Step Output
```bash
# Run with verbose logging
act push -j deploy --secret-file .secrets -v
```

### SSH Issues
If you encounter SSH connection issues during testing:

1. Verify your Lightsail instance security group allows SSH (port 22)
2. Ensure the private key in Secrets Manager is correct
3. Test SSH manually:
   ```bash
   # Decode the base64 key first
   echo "YOUR_BASE64_KEY" | base64 -d > test_key.pem
   chmod 600 test_key.pem
   ssh -i test_key.pem ubuntu@YOUR_LIGHTSAIL_IP
   ```

### AWS Secrets Manager Issues
If the secrets retrieval fails:

1. Verify the IAM user has `secretsmanager:GetSecretValue` permission
2. Check the secret ID/ARN is correct
3. Ensure the region is correct (note: secret may be in different region)
4. Test manually:
   ```bash
   aws secretsmanager get-secret-value \
     --secret-id "arn:aws:secretsmanager:eu-north-1:280648354859:secret:prod/frappe-Aojmb0" \
     --region eu-north-1
   ```

## Limitations

When testing with act:

1. **No real SSH**: act runs in a container, so actual SSH to Lightsail won't work in full test mode
2. **Secrets Manager**: Will make real API calls to AWS
3. **Network**: Network policies in your Docker environment may affect connectivity

## Best Practices

1. **Start with dry runs**: Use `-n` flag first to validate syntax
2. **Use verbose mode**: Add `-v` for detailed logs
3. **Test incrementally**: Test individual jobs with `-j` flag
4. **Validate secrets**: Ensure all secrets are properly set before running
5. **Check permissions**: Verify AWS IAM permissions are correct

## Common Commands

```bash
# List all workflows and jobs
act -l

# Run specific job without execution
act push -j deploy -n --secret-file .secrets

# Run with verbose output
act push -j deploy --secret-file .secrets -v

# Run and enter shell on failure
act push -j deploy --secret-file .secrets --shell

# Use specific workflow file
act -W .github/workflows/deploy.yml

# Simulate push to main
act push --eventpath test-event.json --secret-file .secrets
```

## Troubleshooting

### Issue: "Cannot find Docker"
- Solution: Ensure Docker Desktop is running

### Issue: "Secret not found"
- Solution: Check `.secrets` file exists and has correct format

### Issue: "Permission denied"
- Solution: On Linux, you may need to run with sudo or add user to docker group

### Issue: "Platform not supported"
- Solution: Use the correct platform flag: `--platform linux/amd64`

### Issue: "Container not found"
- Solution: Pull the act images: `docker pull catthehacker/ubuntu:act-latest`

## Next Steps

After successful local testing:

1. Push your changes to GitHub
2. Monitor the workflow in GitHub Actions tab
3. Check deployment logs for any issues
4. Access your Lightsail instance IP to verify the application is running

## Resources

- [act-cli Documentation](https://github.com/nektos/act)
- [GitHub Actions Documentation](https://docs.github.com/en/actions)
- [AWS Secrets Manager](https://docs.aws.amazon.com/secretsmanager/)
- [Lightsail Documentation](https://lightsail.aws.amazon.com/ls/docs/)

