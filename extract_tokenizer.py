import json
import os

def extract_tokenizer():
    input_path = "/Users/scott/ios_app_general/reference_files/wkcn/TinyCLIP-ViT-61M-32-Text-29M-LAION400M/tokenizer.json"
    vocab_output = "/Users/scott/ios_app_general/RPhoto/Resources/tinyclip-vocab.json"
    merges_output = "/Users/scott/ios_app_general/RPhoto/Resources/tinyclip-merges.txt"

    print(f"Reading {input_path}...")
    with open(input_path, 'r') as f:
        data = json.load(f)

    # 1. Extract Vocab
    vocab = data['model']['vocab']
    print(f"Extracting {len(vocab)} vocab items...")
    
    with open(vocab_output, 'w') as f:
        json.dump(vocab, f, ensure_ascii=False, indent=2)
    print(f"Saved vocab to {vocab_output}")

    # 2. Extract Merges
    merges = data['model']['merges']
    print(f"Extracting {len(merges)} merges...")
    
    # Merges in tokenizer.json might be "a b" or "a b 123" (if weighted), but usually just "a b"
    # The current code expects a file where each line is "a b". 
    # Let's inspect the first few merges to be sure.
    
    with open(merges_output, 'w') as f:
        # Add a header comment mostly to match existing file style if any, though existing code skips nothing?
        # Actually existing code code:
        # let bpeMergesTxt = try! String(contentsOf: url)
        # let arr = bpeMergesTxt.split(separator: "\n").map { String($0) }
        # for i in 1 ..< arr.count { ... } 
        # So it skips the first line! We must add a comment or dummy line.
        f.write("#version: 0.2\n") 
        for merge in merges:
            f.write(f"{merge}\n")
    
    print(f"Saved merges to {merges_output}")

if __name__ == "__main__":
    extract_tokenizer()
