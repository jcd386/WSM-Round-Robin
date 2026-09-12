/**
 * WSM Round Robin shared JS-only service module.
 * No template, no meta target: never used as a custom element, only imported
 * for its named exports (import { reduceErrors } from 'c/wsmRrUtils').
 */

/**
 * Flattens Apex/LDS error shapes (single error, array, page error, or
 * AuraHandledException body) into a list of human-readable strings.
 */
export function reduceErrors(errors) {
    if (!errors) {
        return ['Unknown error'];
    }
    if (!Array.isArray(errors)) {
        errors = [errors];
    }
    return errors
        .filter((error) => !!error)
        .map((error) => {
            if (Array.isArray(error.body)) {
                return error.body.map((e) => e.message).join(', ');
            }
            if (error.body && typeof error.body.message === 'string') {
                return error.body.message;
            }
            if (error.body && error.body.pageErrors && error.body.pageErrors.length) {
                return error.body.pageErrors.map((e) => e.message).join(', ');
            }
            if (error.body && error.body.fieldErrors) {
                const fieldErrors = Object.values(error.body.fieldErrors).flat();
                if (fieldErrors.length) {
                    return fieldErrors.map((e) => e.message).join(', ');
                }
            }
            if (typeof error.message === 'string') {
                return error.message;
            }
            if (typeof error.statusText === 'string') {
                return error.statusText;
            }
            return 'Unknown error';
        })
        .filter((message) => !!message);
}

/** Single-string convenience wrapper around reduceErrors. */
export function reduceErrorMessage(error) {
    return reduceErrors(error).join(', ') || 'Unknown error';
}

/** Standard debounce, used for typeahead search fields. */
export function debounce(fn, wait = 300) {
    let timeoutId;
    return (...args) => {
        window.clearTimeout(timeoutId);
        timeoutId = window.setTimeout(() => fn(...args), wait);
    };
}

/** Coarse relative-time formatter ("just now", "5m ago", "3d ago"). */
export function timeAgo(value) {
    if (!value) {
        return '-';
    }
    const then = value instanceof Date ? value : new Date(value);
    const diffMs = Date.now() - then.getTime();
    if (Number.isNaN(diffMs)) {
        return '-';
    }
    const diffSec = Math.round(diffMs / 1000);
    if (diffSec < 5) {
        return 'just now';
    }
    if (diffSec < 60) {
        return `${diffSec}s ago`;
    }
    const diffMin = Math.round(diffSec / 60);
    if (diffMin < 60) {
        return `${diffMin}m ago`;
    }
    const diffHr = Math.round(diffMin / 60);
    if (diffHr < 24) {
        return `${diffHr}h ago`;
    }
    const diffDay = Math.round(diffHr / 24);
    if (diffDay < 30) {
        return `${diffDay}d ago`;
    }
    const diffMon = Math.round(diffDay / 30);
    if (diffMon < 12) {
        return `${diffMon}mo ago`;
    }
    return `${Math.round(diffMon / 12)}y ago`;
}

/** Slugifies a display name into the DeveloperName-safe token used as the flow-facing key. */
export function slugify(value) {
    if (!value) {
        return '';
    }
    let slug = value
        .trim()
        .replace(/[^a-zA-Z0-9]+/g, '_')
        .replace(/_+/g, '_')
        .replace(/^_|_$/g, '');
    if (/^[0-9]/.test(slug)) {
        slug = `X_${slug}`;
    }
    return slug.substring(0, 80);
}

/** Short algorithm badge text: Strict Rotation -> SR, Weighted -> W, Least Assigned -> LA. */
export function algorithmAbbrev(algorithm) {
    switch (algorithm) {
        case 'Strict Rotation':
            return 'SR';
        case 'Weighted':
            return 'W';
        case 'Least Assigned':
            return 'LA';
        case 'Least Loaded':
            return 'LL';
        default:
            return '';
    }
}

export function isWithinDays(value, days) {
    if (!value) {
        return false;
    }
    const then = value instanceof Date ? value : new Date(value);
    const diffMs = Date.now() - then.getTime();
    return diffMs >= 0 && diffMs <= days * 24 * 60 * 60 * 1000;
}
