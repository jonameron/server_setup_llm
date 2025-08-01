# VLLM Usage Guide

## Basic Usage with curl

### Chat Completion
```bash
curl -X POST "http://localhost:8000/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d '{
        "model": "google/gemma-3n-E4B-it",
        "messages": [
            {
                "role": "user",
                "content": "What is the capital of France?"
            }
        ]
    }'
```

### Text Completion
```bash
curl -X POST "http://localhost:8000/v1/completions" \
    -H "Content-Type: application/json" \
    -d '{
        "model": "google/gemma-3n-E4B-it",
        "prompt": "The capital of France is",
        "max_tokens": 100
    }'
```

## Python Example

```python
import requests
import json

def ask_vllm(question):
    url = "http://localhost:8000/v1/chat/completions"
    headers = {"Content-Type": "application/json"}
    
    data = {
        "model": "google/gemma-3n-E4B-it",
        "messages": [
            {
                "role": "user",
                "content": question
            }
        ]
    }
    
    response = requests.post(url, headers=headers, json=data)
    return response.json()

# Example usage
response = ask_vllm("Explain quantum computing in simple terms")
print(json.dumps(response, indent=2))
```

## Using via Tailscale

Replace `localhost:8000` with your Tailscale hostname in any of the above examples:

```bash
curl -X POST "https://your-tailscale-hostname/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d '{
        "model": "google/gemma-3n-E4B-it",
        "messages": [
            {
                "role": "user",
                "content": "Hello!"
            }
        ]
    }'
```

## Available Endpoints

- `/v1/models` - List available models
- `/v1/chat/completions` - Chat interface
- `/v1/completions` - Text completion interface

## Common Parameters

- `max_tokens`: Maximum number of tokens to generate
- `temperature`: Controls randomness (0.0 to 1.0)
- `top_p`: Controls diversity via nucleus sampling
- `stream`: Set to `true` for streaming responses
