using System.Globalization;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.AspNetCore.DataProtection;

const string TradingDashboardBaseUrl = "http://127.0.0.1:5080";
const string TraderBaseUrl = "https://api.schwabapi.com/trader/v1";
const string TokenProtectorPurpose = "TradingDashboard.Schwab.OAuthTokens.v1";
const string DataProtectionApplicationName = "TradingDashboard.SchwabOAuth.v1";
const string DataProtectionKeyDirectory =
    @"D:\AI-Chat GPT\TradingDashboard\App\Dashboard\DataProtection";

if (args.Length == 0)
{
    Console.Error.WriteLine("Usage: SwingSchwabSubmit submit-plan <plan.json> [--dry-run] | cancel-order <account> <orderId> [--dry-run] | auth-status");
    return 2;
}

bool dryRun = args.Contains("--dry-run", StringComparer.OrdinalIgnoreCase);
string command = args[0].Trim().ToLowerInvariant();
using HttpClient http = new();

try
{
    if (command == "auth-status")
    {
        JsonObject result = LoadTokenStatus();
        Console.WriteLine(result.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
        return 0;
    }
    if (command == "submit-pbf-tests")
    {
        JsonArray results = await SubmitPbfTestsAsync(http, dryRun);
        Console.WriteLine(results.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
        return 0;
    }
    if (command == "submit-plan")
    {
        if (args.Length < 2)
            throw new ArgumentException("submit-plan requires a plan JSON path.");
        JsonObject result = await SubmitPlanAsync(http, args[1], dryRun);
        Console.WriteLine(result.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
        return 0;
    }
    if (command == "cancel-order")
    {
        if (args.Length < 3)
            throw new ArgumentException("cancel-order requires an account alias and order id.");
        JsonObject result = await CancelOrderAsync(http, args[1], args[2], dryRun);
        Console.WriteLine(result.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
        return 0;
    }

    Console.Error.WriteLine($"Unknown command: {command}");
    return 2;
}
catch (Exception ex)
{
    Console.Error.WriteLine(ex.Message);
    return 1;
}

static async Task<JsonObject> SubmitPlanAsync(HttpClient http, string planPath, bool dryRun)
{
    JsonObject plan = JsonNode.Parse(await File.ReadAllTextAsync(planPath))?.AsObject()
        ?? throw new InvalidOperationException("Plan JSON was empty or invalid.");
    AccountHashes accounts = await GetAccountHashesAsync(http);
    string account = RequiredString(plan, "account");
    string accountHash = AccountHashFor(accounts, account);
    string assetType = RequiredString(plan, "assetType").ToLowerInvariant();
    string ticker = RequiredString(plan, "ticker").ToUpperInvariant();
    string structure = ((string?)plan["structure"] ?? "").Trim().ToLowerInvariant();
    int quantity = RequiredInt(plan, "quantity");
    decimal triggerPrice = RequiredDecimal(plan, "triggerPrice");
    string phase = ((string?)plan["pricePhase"] ?? "initial").Trim().ToLowerInvariant();

    JsonObject payload;
    JsonObject pricing = new()
    {
        ["phase"] = phase
    };
    if (assetType == "stock")
    {
        Quote quote = await GetQuoteAsync(http, ticker);
        decimal basis = phase == "mark" ? quote.Mark : quote.Bid;
        if (basis <= 0)
            basis = phase == "mark" ? quote.Last : triggerPrice;
        decimal limit = RoundMoney(Math.Min(basis, triggerPrice));
        payload = StockBuyPayload(ticker, quantity, limit);
        pricing["bid"] = Money(quote.Bid);
        pricing["mark"] = Money(quote.Mark);
        pricing["last"] = Money(quote.Last);
        pricing["submittedLimit"] = Money(limit);
    }
    else if (assetType == "option")
    {
        ParsedContractLabel parsed = ParseContractLabel(RequiredString(plan, "contractLabel"));
        Dictionary<decimal, OptionContract> chain = await GetOptionContractsAsync(http, ticker, parsed.Right, parsed.Expiration);
        OptionContract longLeg = Required(chain, parsed.Strikes[0]);
        JsonObject payloadPricing = new();
        if (parsed.Strikes.Count == 1)
        {
            decimal limit = PositiveDebit(phase == "mark" ? longLeg.Mark : longLeg.Bid, $"{ticker} {parsed.Strikes[0]}{parsed.Right[0]} {phase}");
            payload = SingleOptionPayload(longLeg.Symbol, quantity, limit);
            payloadPricing["longBid"] = Money(longLeg.Bid);
            payloadPricing["longAsk"] = Money(longLeg.Ask);
            payloadPricing["longMark"] = Money(longLeg.Mark);
            payloadPricing["submittedLimit"] = Money(limit);
        }
        else
        {
            if (structure == "put_credit_spread")
            {
                if (!parsed.Right.Equals("PUT", StringComparison.OrdinalIgnoreCase))
                    throw new InvalidOperationException($"put_credit_spread requires PUT legs: {plan["contractLabel"]}");
                OptionContract shortPut = Required(chain, parsed.Strikes[0]);
                OptionContract longPut = Required(chain, parsed.Strikes[1]);
                decimal credit = phase == "mark"
                    ? shortPut.Mark - longPut.Mark
                    : shortPut.Bid - longPut.Ask;
                decimal limit = PositiveDebit(credit, $"{ticker} {string.Join("/", parsed.Strikes)}{parsed.Right[0]} {phase} credit");
                payload = VerticalCreditPayload(shortPut.Symbol, longPut.Symbol, quantity, limit);
                payloadPricing["shortBid"] = Money(shortPut.Bid);
                payloadPricing["longAsk"] = Money(longPut.Ask);
                payloadPricing["shortMark"] = Money(shortPut.Mark);
                payloadPricing["longMark"] = Money(longPut.Mark);
                payloadPricing["submittedLimit"] = Money(limit);
            }
            else
            {
                OptionContract shortLeg = Required(chain, parsed.Strikes[1]);
                decimal debit = phase == "mark"
                    ? longLeg.Mark - shortLeg.Mark
                    : longLeg.Bid - shortLeg.Ask;
                decimal limit = PositiveDebit(debit, $"{ticker} {string.Join("/", parsed.Strikes)}{parsed.Right[0]} {phase} debit");
                payload = VerticalDebitPayload(longLeg.Symbol, shortLeg.Symbol, quantity, limit);
                payloadPricing["longBid"] = Money(longLeg.Bid);
                payloadPricing["shortAsk"] = Money(shortLeg.Ask);
                payloadPricing["longMark"] = Money(longLeg.Mark);
                payloadPricing["shortMark"] = Money(shortLeg.Mark);
                payloadPricing["submittedLimit"] = Money(limit);
            }
        }
        pricing = payloadPricing;
        pricing["phase"] = phase;
    }
    else
    {
        throw new InvalidOperationException($"Unsupported assetType: {assetType}");
    }

    JsonObject result = new()
    {
        ["dryRun"] = dryRun,
        ["account"] = account,
        ["ticker"] = ticker,
        ["assetType"] = assetType,
        ["payload"] = payload.DeepClone(),
        ["pricing"] = pricing
    };
    if (!dryRun)
    {
        string accessToken = LoadAccessToken();
        SubmitResult submit = await SubmitAsync(http, accessToken, accountHash, payload);
        result["accepted"] = submit.Accepted;
        result["httpStatus"] = submit.HttpStatus;
        result["location"] = submit.Location;
        result["orderId"] = submit.OrderId;
        result["response"] = submit.ResponseBody;
    }
    return result;
}

static async Task<JsonArray> SubmitPbfTestsAsync(HttpClient http, bool dryRun)
{
    AccountHashes accounts = await GetAccountHashesAsync(http);
    ChainContracts contracts = await GetPbfContractsAsync(http);
    string accessToken = dryRun ? string.Empty : LoadAccessToken();

    decimal stockLimit = 64.83m;
    decimal callPrice = PositiveDebit(contracts.Call60.Bid, "PBF 60C bid");
    decimal spreadDebit = PositiveDebit(
        contracts.Call65.Bid - contracts.Call75.Ask,
        "PBF 65/75C bid-side spread debit");
    decimal callMarkPrice = RoundMoney(contracts.Call60.Mark);
    decimal spreadMarkDebit = PositiveDebit(
        contracts.Call65.Mark - contracts.Call75.Mark,
        "PBF 65/75C mark spread debit");

    var orders = new[]
    {
        new PlannedOrder(
            "PBF stock IRA test",
            accounts.IraHash,
            StockBuyPayload("PBF", 77, stockLimit),
            "IRA"),
        new PlannedOrder(
            "PBF 60C Living Trust test",
            accounts.LivingTrustHash,
            SingleOptionPayload(contracts.Call60.Symbol, 3, callPrice),
            "Living Trust"),
        new PlannedOrder(
            "PBF 65/75C spread Living Trust test",
            accounts.LivingTrustHash,
            VerticalDebitPayload(contracts.Call65.Symbol, contracts.Call75.Symbol, 6, spreadDebit),
            "Living Trust")
    };

    JsonArray results = new();
    foreach (PlannedOrder order in orders)
    {
        JsonObject result = new()
        {
            ["label"] = order.Label,
            ["account"] = order.AccountAlias,
            ["dryRun"] = dryRun,
            ["payload"] = order.Payload.DeepClone()
        };
        if (order.Label.Contains("60C", StringComparison.Ordinal))
            result["fallbackMarkAfter60Seconds"] = Money(callMarkPrice);
        if (order.Label.Contains("65/75C", StringComparison.Ordinal))
            result["fallbackMarkAfter60Seconds"] = Money(spreadMarkDebit);
        if (!dryRun)
        {
            SubmitResult submit = await SubmitAsync(http, accessToken, order.AccountHash, order.Payload);
            result["accepted"] = submit.Accepted;
            result["httpStatus"] = submit.HttpStatus;
            result["location"] = submit.Location;
            result["orderId"] = submit.OrderId;
            result["response"] = submit.ResponseBody;
        }
        results.Add(result);
    }

    return results;
}

static JsonObject StockBuyPayload(string symbol, int quantity, decimal limitPrice) =>
    new()
    {
        ["orderType"] = "LIMIT",
        ["session"] = "NORMAL",
        ["price"] = Money(limitPrice),
        ["duration"] = "DAY",
        ["orderStrategyType"] = "SINGLE",
        ["orderLegCollection"] = new JsonArray
        {
            new JsonObject
            {
                ["instruction"] = "BUY",
                ["quantity"] = quantity,
                ["instrument"] = new JsonObject
                {
                    ["symbol"] = symbol,
                    ["assetType"] = "EQUITY"
                }
            }
        }
    };

static JsonObject SingleOptionPayload(string symbol, int quantity, decimal limitPrice) =>
    new()
    {
        ["orderType"] = "LIMIT",
        ["session"] = "NORMAL",
        ["price"] = Money(limitPrice),
        ["duration"] = "DAY",
        ["orderStrategyType"] = "SINGLE",
        ["orderLegCollection"] = new JsonArray
        {
            new JsonObject
            {
                ["instruction"] = "BUY_TO_OPEN",
                ["quantity"] = quantity,
                ["instrument"] = new JsonObject
                {
                    ["symbol"] = symbol,
                    ["assetType"] = "OPTION"
                }
            }
        }
    };

static JsonObject VerticalDebitPayload(string longSymbol, string shortSymbol, int quantity, decimal debit) =>
    new()
    {
        ["orderType"] = "NET_DEBIT",
        ["session"] = "NORMAL",
        ["price"] = Money(debit),
        ["duration"] = "DAY",
        ["orderStrategyType"] = "SINGLE",
        ["complexOrderStrategyType"] = "VERTICAL",
        ["orderLegCollection"] = new JsonArray
        {
            new JsonObject
            {
                ["instruction"] = "BUY_TO_OPEN",
                ["quantity"] = quantity,
                ["instrument"] = new JsonObject
                {
                    ["symbol"] = longSymbol,
                    ["assetType"] = "OPTION"
                }
            },
            new JsonObject
            {
                ["instruction"] = "SELL_TO_OPEN",
                ["quantity"] = quantity,
                ["instrument"] = new JsonObject
                {
                    ["symbol"] = shortSymbol,
                    ["assetType"] = "OPTION"
                }
            }
        }
    };

static JsonObject VerticalCreditPayload(string shortSymbol, string longSymbol, int quantity, decimal credit) =>
    new()
    {
        ["orderType"] = "NET_CREDIT",
        ["session"] = "NORMAL",
        ["price"] = Money(credit),
        ["duration"] = "DAY",
        ["orderStrategyType"] = "SINGLE",
        ["complexOrderStrategyType"] = "VERTICAL",
        ["orderLegCollection"] = new JsonArray
        {
            new JsonObject
            {
                ["instruction"] = "SELL_TO_OPEN",
                ["quantity"] = quantity,
                ["instrument"] = new JsonObject
                {
                    ["symbol"] = shortSymbol,
                    ["assetType"] = "OPTION"
                }
            },
            new JsonObject
            {
                ["instruction"] = "BUY_TO_OPEN",
                ["quantity"] = quantity,
                ["instrument"] = new JsonObject
                {
                    ["symbol"] = longSymbol,
                    ["assetType"] = "OPTION"
                }
            }
        }
    };
static async Task<SubmitResult> SubmitAsync(
    HttpClient http,
    string accessToken,
    string accountHash,
    JsonObject payload)
{
    string url = $"{TraderBaseUrl}/accounts/{Uri.EscapeDataString(accountHash)}/orders";
    using HttpRequestMessage request = new(HttpMethod.Post, url);
    request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", accessToken);
    request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
    request.Content = new StringContent(payload.ToJsonString(), Encoding.UTF8, "application/json");

    using HttpResponseMessage response = await http.SendAsync(request, HttpCompletionOption.ResponseContentRead);
    string body = await response.Content.ReadAsStringAsync();
    string location = response.Headers.Location?.ToString() ?? string.Empty;
    return new(
        response.IsSuccessStatusCode,
        (int)response.StatusCode,
        location,
        ExtractOrderId(location),
        body);
}

static async Task<JsonObject> CancelOrderAsync(HttpClient http, string accountAlias, string orderId, bool dryRun)
{
    JsonObject result = new()
    {
        ["dryRun"] = dryRun,
        ["account"] = accountAlias,
        ["orderId"] = orderId
    };
    if (dryRun)
    {
        result["accepted"] = true;
        result["httpStatus"] = 0;
        return result;
    }

    AccountHashes accounts = await GetAccountHashesAsync(http);
    string accountHash = AccountHashFor(accounts, accountAlias);
    string accessToken = LoadAccessToken();
    string url = $"{TraderBaseUrl}/accounts/{Uri.EscapeDataString(accountHash)}/orders/{Uri.EscapeDataString(orderId)}";
    using HttpRequestMessage request = new(HttpMethod.Delete, url);
    request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", accessToken);
    request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));

    using HttpResponseMessage response = await http.SendAsync(request, HttpCompletionOption.ResponseContentRead);
    string body = await response.Content.ReadAsStringAsync();
    result["accepted"] = response.IsSuccessStatusCode;
    result["httpStatus"] = (int)response.StatusCode;
    result["response"] = body;
    if (!response.IsSuccessStatusCode)
        throw new InvalidOperationException($"Schwab cancel failed with HTTP {(int)response.StatusCode}: {body}");
    return result;
}

static async Task<AccountHashes> GetAccountHashesAsync(HttpClient http)
{
    string body = await http.GetStringAsync($"{TradingDashboardBaseUrl}/api/schwab/account-numbers");
    JsonNode json = JsonNode.Parse(body) ?? throw new InvalidOperationException("No account-numbers response.");
    List<(string Number, string Hash)> accounts = new();
    VisitAccounts(json, accounts);
    string ira = "";
    string trust = "";
    foreach ((string number, string hash) in accounts)
    {
        if (number.EndsWith("5682", StringComparison.Ordinal))
            ira = hash;
        if (number.EndsWith("9157", StringComparison.Ordinal))
            trust = hash;
    }
    if (string.IsNullOrWhiteSpace(ira) || string.IsNullOrWhiteSpace(trust))
        throw new InvalidOperationException("Could not resolve both IRA and Living Trust account hashes.");
    return new(ira, trust);
}

static void VisitAccounts(JsonNode? node, List<(string Number, string Hash)> accounts)
{
    if (node is JsonObject obj)
    {
        string number = (string?)obj["accountNumber"] ?? "";
        string hash = (string?)obj["hashValue"] ?? "";
        if (!string.IsNullOrWhiteSpace(number) && !string.IsNullOrWhiteSpace(hash))
            accounts.Add((number, hash));
        foreach (KeyValuePair<string, JsonNode?> child in obj)
            VisitAccounts(child.Value, accounts);
    }
    else if (node is JsonArray array)
    {
        foreach (JsonNode? child in array)
            VisitAccounts(child, accounts);
    }
}

static async Task<ChainContracts> GetPbfContractsAsync(HttpClient http)
{
    string url = $"{TradingDashboardBaseUrl}/api/schwab/option-chain?symbol=PBF&contractType=CALL&strikeCount=40&fromDate=2026-09-18&toDate=2026-09-18";
    string body = await http.GetStringAsync(url);
    JsonNode json = JsonNode.Parse(body) ?? throw new InvalidOperationException("No option-chain response.");
    Dictionary<decimal, OptionContract> calls = new();
    JsonObject map = json["callExpDateMap"] as JsonObject ?? throw new InvalidOperationException("No PBF call map.");
    foreach (KeyValuePair<string, JsonNode?> exp in map)
    {
        if (exp.Value is not JsonObject strikes)
            continue;
        foreach (KeyValuePair<string, JsonNode?> strikeNode in strikes)
        {
            decimal strike = decimal.Parse(strikeNode.Key, CultureInfo.InvariantCulture);
            if (strikeNode.Value is not JsonArray contracts || contracts.Count == 0)
                continue;
            if (contracts[0] is not JsonObject contract)
                continue;
            calls[strike] = new(
                (string?)contract["symbol"] ?? "",
                (decimal?)contract["bid"] ?? 0m,
                (decimal?)contract["ask"] ?? 0m,
                (decimal?)contract["mark"] ?? 0m);
        }
    }
    return new(Required(calls, 60m), Required(calls, 65m), Required(calls, 75m));
}

static async Task<Dictionary<decimal, OptionContract>> GetOptionContractsAsync(
    HttpClient http,
    string symbol,
    string right,
    DateOnly expiration)
{
    string contractType = right.Equals("PUT", StringComparison.OrdinalIgnoreCase) ? "PUT" : "CALL";
    string date = expiration.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
    string url = $"{TradingDashboardBaseUrl}/api/schwab/option-chain?symbol={Uri.EscapeDataString(symbol)}&contractType={contractType}&strikeCount=80&fromDate={date}&toDate={date}";
    string body = await http.GetStringAsync(url);
    JsonNode json = JsonNode.Parse(body) ?? throw new InvalidOperationException("No option-chain response.");
    string mapName = contractType == "PUT" ? "putExpDateMap" : "callExpDateMap";
    JsonObject map = json[mapName] as JsonObject ?? throw new InvalidOperationException($"No {symbol} {contractType} map.");
    Dictionary<decimal, OptionContract> contracts = new();
    foreach (KeyValuePair<string, JsonNode?> exp in map)
    {
        if (exp.Value is not JsonObject strikes)
            continue;
        foreach (KeyValuePair<string, JsonNode?> strikeNode in strikes)
        {
            decimal strike = decimal.Parse(strikeNode.Key, CultureInfo.InvariantCulture);
            if (strikeNode.Value is not JsonArray nodes || nodes.Count == 0 || nodes[0] is not JsonObject contract)
                continue;
            contracts[strike] = new(
                (string?)contract["symbol"] ?? "",
                (decimal?)contract["bid"] ?? 0m,
                (decimal?)contract["ask"] ?? 0m,
                (decimal?)contract["mark"] ?? 0m);
        }
    }
    return contracts;
}

static async Task<Quote> GetQuoteAsync(HttpClient http, string symbol)
{
    string body = await http.GetStringAsync($"{TradingDashboardBaseUrl}/api/schwab/quotes?symbols={Uri.EscapeDataString(symbol)}");
    JsonNode root = JsonNode.Parse(body) ?? throw new InvalidOperationException("No quote response.");
    JsonObject quote = root[symbol]?["quote"] as JsonObject
        ?? throw new InvalidOperationException($"No quote block found for {symbol}.");
    decimal bid = (decimal?)quote["bidPrice"] ?? 0m;
    decimal ask = (decimal?)quote["askPrice"] ?? 0m;
    decimal mark = (decimal?)quote["mark"] ?? (bid > 0 && ask > 0 ? (bid + ask) / 2m : 0m);
    decimal last = (decimal?)quote["lastPrice"] ?? mark;
    return new(bid, ask, mark, last);
}

static OptionContract Required(Dictionary<decimal, OptionContract> calls, decimal strike)
{
    if (!calls.TryGetValue(strike, out OptionContract value))
        throw new InvalidOperationException($"PBF {strike}C was not found in the option chain.");
    if (string.IsNullOrWhiteSpace(value.Symbol) || value.Mark <= 0)
        throw new InvalidOperationException($"PBF {strike}C had an unusable symbol or mark.");
    return value;
}

static ParsedContractLabel ParseContractLabel(string label)
{
    System.Text.RegularExpressions.Match match = System.Text.RegularExpressions.Regex.Match(
        label.Trim(),
        @"^(?<strikes>[0-9.]+(?:/[0-9.]+)*)\s*(?<right>[CP])\s+(?<month>\d{2})-(?<day>\d{2})$",
        System.Text.RegularExpressions.RegexOptions.IgnoreCase);
    if (!match.Success)
        throw new InvalidOperationException($"Could not parse contract label: {label}");
    int year = DateTime.Today.Year;
    DateOnly expiration = new(
        year,
        int.Parse(match.Groups["month"].Value, CultureInfo.InvariantCulture),
        int.Parse(match.Groups["day"].Value, CultureInfo.InvariantCulture));
    string right = match.Groups["right"].Value.Equals("P", StringComparison.OrdinalIgnoreCase)
        ? "PUT"
        : "CALL";
    IReadOnlyList<decimal> strikes = match.Groups["strikes"].Value
        .Split('/')
        .Select(x => decimal.Parse(x, CultureInfo.InvariantCulture))
        .ToList();
    return new(expiration, right, strikes);
}

static string AccountHashFor(AccountHashes accounts, string alias)
{
    if (alias.Equals("IRA", StringComparison.OrdinalIgnoreCase))
        return accounts.IraHash;
    if (alias.Equals("Living Trust", StringComparison.OrdinalIgnoreCase))
        return accounts.LivingTrustHash;
    throw new InvalidOperationException($"No account hash mapping for {alias}.");
}

static string RequiredString(JsonObject obj, string name) =>
    (string?)obj[name] ?? throw new InvalidOperationException($"{name} is required.");

static int RequiredInt(JsonObject obj, string name) =>
    (int?)obj[name] ?? throw new InvalidOperationException($"{name} is required.");

static decimal RequiredDecimal(JsonObject obj, string name) =>
    (decimal?)obj[name] ?? throw new InvalidOperationException($"{name} is required.");

static JsonObject LoadTokenStatus()
{
    JsonObject result = new();
    try
    {
        JsonNode node = LoadTokenNode(out string tokenPath, out string keyDirectory);
        DateTime expires = (DateTime?)node["AccessTokenExpiresUtc"] ?? DateTime.MinValue;
        result["ok"] = expires > DateTime.UtcNow.AddMinutes(1) && !string.IsNullOrWhiteSpace((string?)node["AccessToken"]);
        result["tokenPath"] = tokenPath;
        result["keyDirectory"] = keyDirectory;
        result["accessTokenExpiresUtc"] = expires;
        result["authorizedUtc"] = (DateTime?)node["AuthorizedUtc"];
        result["updatedUtc"] = (DateTime?)node["UpdatedUtc"];
    }
    catch (Exception ex)
    {
        result["ok"] = false;
        result["error"] = ex.Message;
    }
    return result;
}

static string LoadAccessToken()
{
    JsonNode node = LoadTokenNode(out _, out _);
    DateTime expires = (DateTime?)node["AccessTokenExpiresUtc"] ?? DateTime.MinValue;
    if (expires <= DateTime.UtcNow.AddMinutes(1))
        throw new InvalidOperationException($"Schwab access token is expired or too close to expiry: {expires:O}");
    return (string?)node["AccessToken"]
        ?? throw new InvalidOperationException("OAuth token did not include AccessToken.");
}

static JsonNode LoadTokenNode(out string tokenPath, out string keyDirectory)
{
    tokenPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "TradingDashboard",
        "Schwab",
        "oauth-token.protected");
    if (!File.Exists(tokenPath))
        throw new InvalidOperationException($"Protected token file was not found: {tokenPath}");

    List<string> keyDirectories = new()
    {
        Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "TradingDashboard",
            "DataProtection-Keys"),
        DataProtectionKeyDirectory
    };
    Exception? lastError = null;
    foreach (string candidate in keyDirectories.Where(Directory.Exists).Distinct(StringComparer.OrdinalIgnoreCase))
    {
        try
        {
            IDataProtector protector = DataProtectionProvider.Create(
                    new DirectoryInfo(candidate),
                    builder => builder.SetApplicationName(DataProtectionApplicationName).ProtectKeysWithDpapi())
                .CreateProtector(TokenProtectorPurpose);
            string json = protector.Unprotect(File.ReadAllText(tokenPath));
            keyDirectory = candidate;
            return JsonNode.Parse(json) ?? throw new InvalidOperationException("Could not parse OAuth token.");
        }
        catch (Exception ex) when (ex is System.Security.Cryptography.CryptographicException or IOException or UnauthorizedAccessException)
        {
            lastError = ex;
        }
    }
    throw new InvalidOperationException($"Could not decrypt OAuth token with any known key directory: {lastError?.Message}");
}

static string ExtractOrderId(string location)
{
    if (string.IsNullOrWhiteSpace(location))
        return "";
    string path = Uri.TryCreate(location, UriKind.Absolute, out Uri? uri)
        ? uri.AbsolutePath
        : location;
    string value = path.Split('/', StringSplitOptions.RemoveEmptyEntries).LastOrDefault() ?? "";
    return value.Equals("orders", StringComparison.OrdinalIgnoreCase) ? "" : value;
}

static decimal RoundMoney(decimal value) => Math.Round(value, 2, MidpointRounding.AwayFromZero);

static string Money(decimal value) => value.ToString("0.00", CultureInfo.InvariantCulture);

static decimal PositiveDebit(decimal value, string label)
{
    decimal rounded = RoundMoney(value);
    if (rounded <= 0)
        throw new InvalidOperationException($"{label} did not produce a positive debit.");
    return rounded;
}

sealed record AccountHashes(string IraHash, string LivingTrustHash);
sealed record OptionContract(string Symbol, decimal Bid, decimal Ask, decimal Mark);
sealed record ChainContracts(OptionContract Call60, OptionContract Call65, OptionContract Call75);
sealed record PlannedOrder(string Label, string AccountHash, JsonObject Payload, string AccountAlias);
sealed record SubmitResult(bool Accepted, int HttpStatus, string Location, string OrderId, string ResponseBody);
sealed record ParsedContractLabel(DateOnly Expiration, string Right, IReadOnlyList<decimal> Strikes);
sealed record Quote(decimal Bid, decimal Ask, decimal Mark, decimal Last);
