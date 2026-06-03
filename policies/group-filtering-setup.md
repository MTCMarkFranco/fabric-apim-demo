# Group-Based Access Filtering via JWT Policy

Filter access to the Fabric MCP endpoint based on the caller's Entra ID security group membership, enforced directly in the APIM inbound policy.

## Prerequisites

1. An Entra ID security group containing authorized users
2. The group's **Object ID** (found in Entra ID → Groups → your group → Overview)

## Step 1: Configure Group Claims in the App Registration

1. Go to **Entra ID → App Registrations → your app**
2. Navigate to **Token Configuration → Add groups claim**
3. Select **Security groups**
4. For the token type (Access), choose **Group ID** as the format
5. Save

This causes Entra to emit a `groups` claim in the access token containing the Object IDs of the user's security groups.

## Step 2: Add the Policy Check

After the `validate-azure-ad-token` element in your inbound policy, add a `<choose>` block that inspects the `groups` claim:

```xml
<!-- Require membership in the allowed security group -->
<choose>
    <when condition="@{
        var jwt = (Jwt)context.Variables[&quot;validated-jwt&quot;];
        var allowedGroupId = &quot;YOUR-SECURITY-GROUP-OBJECT-ID&quot;;
        var groups = jwt.Claims.GetValueOrDefault(&quot;groups&quot;, &quot;&quot;);
        return groups.Contains(allowedGroupId);
    }">
        <!-- Authorized — continue -->
    </when>
    <otherwise>
        <return-response>
            <set-status code="403" reason="Forbidden" />
            <set-body>{"error":"User is not a member of the required security group."}</set-body>
        </return-response>
    </otherwise>
</choose>
```

Replace `YOUR-SECURITY-GROUP-OBJECT-ID` with the actual Object ID of your security group.

## Step 3: Handle Token Overage (200+ Groups)

If a user is a member of more than 200 groups, Entra does **not** include the `groups` claim in the token. Instead it emits a `_claim_names` property indicating an overage. You have two options:

### Option A: Use app role assignments instead of group claims

1. In the App Registration, go to **App Roles → Create app role**
2. Assign the security group to that app role via **Enterprise Applications → your app → Users and groups → Add assignment**
3. Check the `roles` claim in the policy instead of `groups` — this is never subject to overage

### Option B: Call Microsoft Graph on overage

Add a conditional `send-request` to the Microsoft Graph `/me/memberOf` endpoint when the `groups` claim is missing. This adds latency and requires the APIM instance to have a managed identity with `GroupMember.Read.All` permissions.

**Recommendation:** Option A (app roles) is simpler and avoids the overage problem entirely.

## Multiple Allowed Groups

Store group IDs in an APIM **Named Value** (e.g., `allowed-group-ids` = `id1,id2,id3`) and split in the policy:

```xml
<when condition="@{
    var jwt = (Jwt)context.Variables[&quot;validated-jwt&quot;];
    var allowedIds = &quot;{{allowed-group-ids}}&quot;.Split(',');
    var groups = jwt.Claims.GetValueOrDefault(&quot;groups&quot;, &quot;&quot;);
    return allowedIds.Any(id => groups.Contains(id.Trim()));
}">
```

## Adding a Dimension to Metrics

To track authorized vs. denied requests in your custom metrics, add a dimension:

```xml
<dimension name="Authorized" value="@(context.Response != null ? "true" : "false")" />
```

## Testing

1. Get a token for a user **in** the group → expect 200
2. Get a token for a user **not in** the group → expect 403
3. Remove the user from the group, wait for token expiry, re-authenticate → expect 403
