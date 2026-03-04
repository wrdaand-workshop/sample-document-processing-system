# FixBedrockModel.ps1
# Run this AFTER CodeSetupScript has completed.
# Replaces deprecated Claude 3.x model IDs with Claude Haiku 4.5,
# adds error logging, rebuilds the app, and restarts it.

param(
    [string]$ProjectDirectory = "C:\MAM319\DPS",
    [string]$NewModelId = "us.anthropic.claude-haiku-4-5-20251001-v1:0"
)

if (-not (Test-Path $ProjectDirectory)) {
    Write-Host "ERROR: Directory not found: $ProjectDirectory" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "=== Fix Bedrock Model ===" -ForegroundColor Cyan

# --- Stop only the app running from this project directory ---
Write-Host "Stopping app process for $ProjectDirectory ..." -ForegroundColor Cyan
$stoppedAny = $false
Get-Process -Name "dotnet" -ErrorAction SilentlyContinue | ForEach-Object {
    try {
        $cmdLine = (Get-CimInstance Win32_Process -Filter "ProcessId = $($_.Id)" -ErrorAction SilentlyContinue).CommandLine
        if ($cmdLine -and $cmdLine -like "*$ProjectDirectory*") {
            Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
            Write-Host "  Stopped PID $($_.Id)" -ForegroundColor Green
            $stoppedAny = $true
        }
    } catch {}
}
if (-not $stoppedAny) {
    Write-Host "  No matching dotnet process found (may not be running)." -ForegroundColor Yellow
}
Start-Sleep -Seconds 2

Write-Host "Updating model IDs to: $NewModelId" -ForegroundColor Cyan
Write-Host ""

$totalUpdated = 0

# --- Step 1: Update model IDs in appsettings*.json ---

$jsonFiles = Get-ChildItem -Path $ProjectDirectory -Filter "appsettings*.json" -Recurse -ErrorAction SilentlyContinue |
    Where-Object { $_.Directory.FullName -notmatch '\\bin\\|\\obj\\|\\packages\\|\\node_modules\\' }

foreach ($file in $jsonFiles) {
    $content = Get-Content -Path $file.FullName -Raw
    $original = $content
    # Replace any model ID (with any number of us. prefixes) to the correct value
    # This handles: anthropic.claude-*, us.anthropic.claude-*, us.us.anthropic.claude-*, etc.
    $content = $content -replace '(us\.)*anthropic\.claude-[a-zA-Z0-9\.\-]+v\d+:\d+', $NewModelId
    $changed = $content -ne $original
    if ($changed) {
        Set-Content -Path $file.FullName -Value $content -Force
        Write-Host "  Updated: $($file.FullName)" -ForegroundColor Green
        $totalUpdated++
    }
}

Write-Host ""
if ($totalUpdated -eq 0) {
    Write-Host "No deprecated model IDs found in appsettings. Files may already be up to date." -ForegroundColor Yellow
} else {
    Write-Host "Updated $totalUpdated config file(s)." -ForegroundColor Green
}

# --- Step 2: Overwrite C# files with fixed versions (error logging + correct model) ---
# We overwrite the entire files to avoid fragile string-matching on Windows line endings.

Write-Host ""
Write-Host "Writing fixed C# source files..." -ForegroundColor Cyan

# --- DocumentProcessingService.cs ---
$dpsFile = Get-ChildItem -Path $ProjectDirectory -Filter "DocumentProcessingService.cs" -Recurse -ErrorAction SilentlyContinue |
    Where-Object { $_.Directory.FullName -notmatch '\\bin\\|\\obj\\|\\packages\\|\\node_modules\\' } |
    Select-Object -First 1

if ($dpsFile) {
    $dpsContent = @'
using DocumentProcessor.Web.Models;
using DocumentProcessor.Web.Data;
using Microsoft.EntityFrameworkCore;

namespace DocumentProcessor.Web.Services;

public class DocumentProcessingService(IServiceScopeFactory scopeFactory)
{
    public async Task ProcessDocumentAsync(Guid documentId)
    {
        using var scope = scopeFactory.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        var storage = scope.ServiceProvider.GetRequiredService<FileStorageService>();
        var ai = scope.ServiceProvider.GetRequiredService<AIService>();

        var doc = await db.Documents.FindAsync(documentId);
        if (doc == null) return;

        try
        {
            doc.Status = DocumentStatus.Processing;
            await db.SaveChangesAsync();

            await using var stream1 = await storage.GetDocumentAsync(doc.StoragePath);
            await using var stream2 = await storage.GetDocumentAsync(doc.StoragePath);

            var classification = await ai.ClassifyDocumentAsync(doc, stream1);
            var summary = await ai.SummarizeDocumentAsync(doc, stream2);

            doc.Status = DocumentStatus.Processed;
            doc.Summary = summary.Summary;
            await db.SaveChangesAsync();
        }
        catch (Exception ex)
        {
            doc.Status = DocumentStatus.Failed;
            doc.Summary = "ERROR: " + ex.Message;
            Console.Error.WriteLine("========================================");
            Console.Error.WriteLine("[DocumentProcessing] ERROR: " + ex.ToString());
            Console.Error.WriteLine("========================================");
            await db.SaveChangesAsync();
        }
    }
}
'@
    Set-Content -Path $dpsFile.FullName -Value $dpsContent -Force
    Write-Host "  Wrote: $($dpsFile.FullName)" -ForegroundColor Green
} else {
    Write-Host "  WARNING: DocumentProcessingService.cs not found!" -ForegroundColor Yellow
}

# --- AIService.cs ---
$aiFile = Get-ChildItem -Path $ProjectDirectory -Filter "AIService.cs" -Recurse -ErrorAction SilentlyContinue |
    Where-Object { $_.Directory.FullName -notmatch '\\bin\\|\\obj\\|\\packages\\|\\node_modules\\' } |
    Select-Object -First 1

if ($aiFile) {
    $aiContent = @'
using System.Text;
using System.Text.Json;
using Amazon;
using Amazon.BedrockRuntime;
using Amazon.BedrockRuntime.Model;
using DocumentProcessor.Web.Models;
using UglyToad.PdfPig;
using UglyToad.PdfPig.DocumentLayoutAnalysis.TextExtractor;

namespace DocumentProcessor.Web.Services;

public class AIService(IConfiguration configuration)
{
    private readonly IAmazonBedrockRuntime _bedrock = new AmazonBedrockRuntimeClient(new AmazonBedrockRuntimeConfig { RegionEndpoint = RegionEndpoint.GetBySystemName(configuration["Bedrock:Region"] ?? "us-west-2") });

    public async Task<ClassificationResult> ClassifyDocumentAsync(Document document, Stream content)
    {
        var text = await ExtractTextAsync(document, content);
        var prompt = $"Classify this document. Respond with JSON: {{\"category\": \"Invoice\", \"confidence\": 0.95}}\n\nFile: {document.FileName}\n{text}";
        Console.Error.WriteLine("[AIService] Calling Bedrock for classification...");
        var response = await CallBedrockAsync(prompt);
        Console.Error.WriteLine("[AIService] Bedrock classification response received.");
        return ParseClassification(response);
    }

    public async Task<SummaryResult> SummarizeDocumentAsync(Document document, Stream content)
    {
        var text = await ExtractTextAsync(document, content);
        var prompt = $"Summarize in 500 characters:\n\nFile: {document.FileName}\n{text}";
        Console.Error.WriteLine("[AIService] Calling Bedrock for summarization...");
        var summary = await CallBedrockAsync(prompt);
        Console.Error.WriteLine("[AIService] Bedrock summarization response received.");
        return new SummaryResult { Summary = summary.Trim() };
    }

    private async Task<string> CallBedrockAsync(string prompt)
    {
        var modelId = configuration["Bedrock:ClassificationModelId"] ?? "PLACEHOLDER_MODEL_ID";
        Console.Error.WriteLine("[AIService] Using model: " + modelId);
        var request = new ConverseRequest
        {
            ModelId = modelId,
            Messages = [new Message { Role = ConversationRole.User, Content = [new ContentBlock { Text = prompt }] }],
            InferenceConfig = new InferenceConfiguration { MaxTokens = 2000, Temperature = 0.3f }
        };
        var response = await _bedrock.ConverseAsync(request);
        return response.Output?.Message?.Content?.FirstOrDefault()?.Text ?? "";
    }

    private async Task<string> ExtractTextAsync(Document doc, Stream stream)
    {
        var ext = Path.GetExtension(doc.FileName)?.ToLower();
        if (ext == ".pdf")
        {
            var sb = new StringBuilder();
            await Task.Run(() =>
            {
                using var pdf = PdfDocument.Open(stream);
                foreach (var page in pdf.GetPages().Take(5))
                {
                    sb.AppendLine(ContentOrderTextExtractor.GetText(page));
                    if (sb.Length > 10000) break;
                }
            });
            return sb.ToString();
        }
        if (ext == ".txt" || ext == ".log")
        {
            using var reader = new StreamReader(stream);
            var text = await reader.ReadToEndAsync();
            return text.Length > 10000 ? text[..10000] : text;
        }
        return $"[Unsupported: {ext}]";
    }

    private ClassificationResult ParseClassification(string response)
    {
        try
        {
            var cleaned = response.Replace("```json", "").Replace("```", "").Trim();
            var start = cleaned.IndexOf('{');
            var end = cleaned.LastIndexOf('}');
            if (start >= 0 && end > start) cleaned = cleaned[start..(end + 1)];
            var json = JsonDocument.Parse(cleaned);
            return new ClassificationResult { PrimaryCategory = json.RootElement.GetProperty("category").GetString() ?? "Unknown" };
        }
        catch (Exception ex) { Console.Error.WriteLine("[AIService] Classification parse error: " + ex.Message); return new ClassificationResult { PrimaryCategory = "Unknown" }; }
    }
}

public class ClassificationResult
{
    public string PrimaryCategory { get; set; } = "";
}

public class SummaryResult
{
    public string Summary { get; set; } = "";
}
'@
    # Replace the placeholder with the actual model ID parameter
    $aiContent = $aiContent -replace 'PLACEHOLDER_MODEL_ID', $NewModelId
    Set-Content -Path $aiFile.FullName -Value $aiContent -Force
    Write-Host "  Wrote: $($aiFile.FullName)" -ForegroundColor Green
} else {
    Write-Host "  WARNING: AIService.cs not found!" -ForegroundColor Yellow
}

# --- Step 3: Rebuild ---

Write-Host ""
Write-Host "Rebuilding application..." -ForegroundColor Cyan

Push-Location $ProjectDirectory
$buildOutput = dotnet build --configuration Release 2>&1
$buildExitCode = $LASTEXITCODE
Pop-Location

if ($buildExitCode -ne 0) {
    Write-Host "ERROR: Build failed!" -ForegroundColor Red
    $buildOutput | ForEach-Object { Write-Host $_ }
    exit 1
}
Write-Host "Build succeeded." -ForegroundColor Green

# --- Step 4: Restart the app ---

Write-Host ""
Write-Host "Restarting application..." -ForegroundColor Cyan

$webProject = Get-ChildItem -Path $ProjectDirectory -Filter "*.csproj" -Recurse -ErrorAction SilentlyContinue |
    Where-Object { (Get-Content $_.FullName -Raw) -match 'Microsoft\.NET\.Sdk\.Web' } |
    Select-Object -First 1

if ($webProject) {
    Write-Host "Starting: $($webProject.FullName)" -ForegroundColor Cyan
    $env:ASPNETCORE_ENVIRONMENT = "Production"
    Push-Location $ProjectDirectory
    Start-Process -FilePath "dotnet" -ArgumentList "run","--project",$webProject.FullName,"--configuration","Release" -NoNewWindow
    Pop-Location
    Write-Host ""
    Write-Host "App restarted. Wait a few seconds then refresh your browser." -ForegroundColor Green
} else {
    Write-Host "Could not find web project. Please restart the app manually:" -ForegroundColor Yellow
    Write-Host "  cd $ProjectDirectory" -ForegroundColor Yellow
    Write-Host "  dotnet run --configuration Release" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "=== Done! ===" -ForegroundColor Green
